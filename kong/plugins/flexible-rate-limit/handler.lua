-- If you're not sure your plugin is executing, uncomment the line below and restart Kong
-- then it will throw an error which indicates the plugin is being loaded at least.
-- assert(ngx.get_phase() == "timer", "Request Validator CE coming to an end!")

-- Grab pluginname from module name
local plugin_name = ({...})[1]:match("^kong%.plugins%.([^%.]+)")

-- load the base plugin object and create a subclass
local plugin = require("kong.plugins.base_plugin"):extend()

local redis = require("resty.redis")
local socket = require("socket")
local util = require("kong.plugins.flexible-rate-limit.string_util")

-- load graphql-parser
local GqlParser = require("graphql-parser")

local sock_err_count = 0
local sock_err_time = 0

-- constructor
function plugin:new()
  plugin.redis_script_hash = nil
  plugin.super.new(self, plugin_name)
end

function tableContains(table, element)
  for _, value in pairs(table) do
    if value == element then
      return true
    end
  end
  return false
end

function getCfgList(config, request, path) 
  local urlCfg = config.exact_match and config.exact_match[path]
  if nil ~= urlCfg and type(urlCfg) == "table" then
    -- if the method is GET, then we try "GET" and "*"
    local cfgList = urlCfg[request.get_method()] or urlCfg["*"]
    if nil ~= cfgList then return cfgList end
  end
  
  if config.pattern_match and type(config.pattern_match) == "table" then
    for pattern, urlCfg in pairs(config.pattern_match) do
      if string.match(path, pattern) then
        local cfgList = urlCfg[request.get_method()] or urlCfg["*"]
        if nil ~= cfgList then return cfgList end
      end
    end
  end

  local gqlCfg = config.graphql_match and config.graphql_match[path]
  if nil ~= gqlCfg and type(gqlCfg) == "table" then
    local requestBody = request.get_raw_body()
    local gqlTable

    -- according to documentation, a single request body can only
    -- contain queries, mutations or subscriptions but cannot
    -- combine multiple types
    -- this part is also a bit flawed, it will get the first match, then try if it works

    if nil ~= requestBody:find("query") then
      gqlTable = requestBody:gmatch("query.*%{.*}")
    elseif nil ~= requestBody:find("mutation") then
      gqlTable = requestBody:gmatch("mutation.*%{.*}")
    elseif nil ~= requestBody:find("subscription") then
      gqlTable = requestBody:gmatch("subscription.*%{.*}")   
    end

    if nil ~= gqlTable then
      local parser = GqlParser:new()
      for gqlOperation in gqlTable do
        local gqlObject = parser:parse(gqlOperation)
        if nil ~= gqlObject then
          for _, gqlType in pairs(gqlObject:listOps()) do
            for _, gqlName in pairs(gqlType:getRootFields()) do
              local cfgList = gqlCfg[gqlType["type"]][gqlName["name"]]
              if nil ~= cfgList then return cfgList end
            end
          end 
        end
      end
    end
  end

  return nil
end

function xnor(a,b)
  if a == b then return true else return false end
end

function plugin:access(config)
  plugin.super.access(self)

  local debug = config.debug
  local err_code = config.err_code or 426
  local err_msg = config.err_msg or "Too Many Requests"

  -- get per url config object, does not include querystring according to Kong doc
  local path = kong.request.get_path()

  if nil ~= path then
    path = string.gsub(path, "//", "/")
  end

  local redis_backoff_count = config.redis_backoff_count or 10
  local redis_backoff_period = (config.redis_backoff_period or 300000) / 1000
  if sock_err_count >= redis_backoff_count then
    if (sock_err_time + redis_backoff_period) > socket.gettime() then
      if debug then
        kong.log.debug("Backoff period: " .. path)
      end
      return
    else
      -- passed the backoff_period, clear the counter
      sock_err_count = 0
    end
  end

  local cfgList = getCfgList(config, kong.request, path)
  if nil == cfgList then
    if debug then
      kong.log.debug("Not rate limited: " .. kong.request.get_method() .. " " .. path)
    end
    return
  end

  local rd = redis:new()
  local redis_host = config.redis_host or os.getenv("FLEXIBLE_RATE_LIMIT_REDIS_HOST") or "127.0.0.1"
  local redis_port = tonumber(config.redis_port or os.getenv("FLEXIBLE_RATE_LIMIT_REDIS_PORT") or 6379)
  -- in order for os.getenv() to work, you need to specify the following in nginx.config
  -- `env FLEXIBLE_RATE_LIMIT_REDIS_AUTH;`
  -- see https://github.com/openresty/lua-nginx-module#system-environment-variable-support
  local redis_auth = config.redis_auth or os.getenv("FLEXIBLE_RATE_LIMIT_REDIS_AUTH")
  local b1 = config.redis_ssl 
  local redis_ssl = false
  if nil ~= b1 then
    redis_ssl = b1
  else
    local s1 = os.getenv("FLEXIBLE_RATE_LIMIT_REDIS_SSL")
    if nil ~= s1 and "true" == string.lower(s1) then
      redis_ssl = true
    end
  end
  local pool_size = config.pool_size or 50
  local backlog = config.backlog or 50
  local timeout = config.timeout
  if nil ~= timeout and timeout > 0 then 
    rd:set_timeout(timeout)
  end
  local ok, err = rd:connect(redis_host, redis_port, {pool_size = pool_size, backlog = backlog})
  if not ok then
    sock_err_count = sock_err_count + 1
    sock_err_time = socket.gettime()
    kong.log.err("Error connecting to Redis: " .. tostring(err))
    return
  else
    sock_err_count = 0
  end
  -- redis_ssl is only supported in Kong 1.4, we do it manually
  if redis_ssl then
    local sock = rawget(rd, "_sock")
    -- https://openresty-reference.readthedocs.io/en/latest/Lua_Nginx_API/#tcpsocksslhandshake
    -- the first arg is reused_session, it is not so useful if the connection pool is enabled
    local session, err = sock:sslhandshake(nil, redis_host, false)
    if nil ~= err then
      kong.log.err("Error sslhandshake: " .. tostring(err))
      rd:close()
      return
    end
  end
  if nil ~= redis_auth and string.len(redis_auth) > 0 then
    ok, err = rd:auth(redis_auth)
    if not ok then 
      kong.log.err("Error authenticating to Redis: " .. tostring(err))
      rd:close()
      return
    end
  end

  if nil == plugin.redis_script_hash then
    local hash, err = rd:script("load", [[local count = redis.call("incr",KEYS[1])
      if tonumber(count) == 1 then
        redis.call("pexpire",KEYS[1],KEYS[2])
      end
      return count]])
    if not hash then
      kong.log.err("Error redis.script_load(): " .. tostring(err))
      rd:close()
      return
    end
    kong.log.err("Redis script loaded successfully: " .. hash)
    plugin.redis_script_hash = hash
  end

  for i, cfg in ipairs(cfgList) do
    local redis_key = util.interpolate(cfg.redis_key, path, kong.request.get_method(), kong.client.get_forwarded_ip(), kong.request)
    if debug then
      kong.log.debug("Rate limit redis_key: " .. path .. " -> " .. redis_key)
    end
    local trigger = true
    -- the additonal part for trigger condition
    if cfg.trigger_condition then
      local trigger_condition = util.interpolate( cfg.trigger_condition, path, kong.request.get_method(), kong.client.get_forwarded_ip(), kong.request)
      if debug then
        kong.log.debug("Trigger condition: " .. trigger_condition)
      end
      if nil ~= cfg.trigger_values and type(cfg.trigger_values) == "table" then
        if nil ~= cfg.not_trigger_values and type(cfg.not_trigger_values) == "table" then
          kong.log.warn("Use of trigger_condition should have either trigger_values or not_trigger_values, but both are defined for: " .. cfg.redis_key)
        end
        trigger = tableContains(cfg.trigger_values, trigger_condition)
      elseif nil ~= cfg.not_trigger_values and type(cfg.not_trigger_values) == "table" then
        trigger = (not tableContains(cfg.not_trigger_values, trigger_condition))
      end
    end
    if trigger then
      -- rate limitation counting logic
      local w = cfg.window or 1000
      if w <= 10 then w = w * 1000 end
      local count
      count, err = rd:evalsha(plugin.redis_script_hash, 2, redis_key, w)
      if not count then
        kong.log.err("Error calling redis.evalsha(): result: " .. tostring(count) .. ", error: " .. tostring(err))
        if string.match(tostring(err), "^NOSCRIPT") then
          -- script will be re-upload next time
          plugin.redis_script_hash = nil
          -- no script, no need to continue
          rd:close()
          return
        end
      else
        if count > cfg.limit then
          -- there is a race condition in the old implementation, that if somehow, we failed to call rd:pexpire(), then the key will stay here forever
          -- therefore, we need to periodically check for the ttl, if unexpected condition detected, we will delete the key
          local x = count - cfg.limit
          local invalid_key = false
          -- we will check when x = 1, 2, 3, 4, 10, 20, 30, ....
          if (x <= 4) or ((x % 10) == 0) then
            local ttl = rd:pttl(redis_key)
            -- "-1" means no ttl, if we see this, we need to delete the key
            if ttl == -1 then
              kong.log.err("Redis key exists but has no associated expire, will delete it: " .. redis_key)
              local ans
              ans, err = rd:del(redis_key)
              if nil == ans then
                kong.log.err("Error deleting Redis key: " .. redis_key .. ", reason: " .. tostring(err))
              end
              invalid_key = true
            end
          end
          if not invalid_key then
            -- remember to cloes redis after use
            rd:set_keepalive()
            -- if the cfg block defined err_code and err_msg, use it, otherwise, use global err_code and err_msg
            kong.response.exit(cfg.err_code or err_code, cfg.err_msg or err_msg)
            return
          end
        end
      end
    end
  end

  -- remember to cloes redis after use
  rd:set_keepalive()
end

-- set the plugin priority, which determines plugin execution order
plugin.PRIORITY = 840

-- return our plugin object
return plugin
