-- If you're not sure your plugin is executing, uncomment the line below and restart Kong
-- then it will throw an error which indicates the plugin is being loaded at least.
-- assert(ngx.get_phase() == "timer", "Request Validator CE coming to an end!")

-- Grab pluginname from module name
local plugin_name = ({...})[1]:match("^kong%.plugins%.([^%.]+)")

-- load the base plugin object and create a subclass
local plugin = require("kong.plugins.base_plugin"):extend()

local redis = require("resty.redis")
local socket = require("socket")

local sock_err_count = 0
local sock_err_time = 0

-- constructor
function plugin:new()
  plugin.super.new(self, plugin_name)
end

function substituteVariables(template, url, method, ip, request) 
  local output = template:gsub("%$%{[^%}]+%}", function(key) 
      local key2 = key:sub(3, -2)
      if key2 == "url" then
        return url
      elseif key2 == "ip" then
        return ip
      elseif key2 == "method" then
        return method
      else
        local idx = key2:find(".", 1, true)
        if not idx then
            return key
        end
        local prefix = key2:sub(1, idx-1)
        local suffix = key2:sub(idx+1)
        if prefix == "header" then
            return request.get_header(suffix) or key
        elseif prefix == "body" then
            local body = request.get_body()
            if nil == body then return key end
            return body[suffix] or key
        elseif prefix == "query" then
            local query = request.get_query()
            if nil == query then return key end
            return query[suffix] or key
        else
            return key
        end
      end
  end)
  return output
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

  return nil
end

function triggerConditionValid(cfg, path) -- condition config validation
  if cfg.trigger_condition then
    -- trigger condition validation
    if cfg.trigger_values and cfg.not_trigger_values then
      kong.log.err("Error trigger_condition configruation, " .. "path: " .. path .. " redis_key: " .. cfg.redis_key)
      return false
    elseif (cfg.trigger_values or cfg.not_trigger_values) then
      if (type(cfg.trigger_values) == "table" or type(cfg.not_trigger_values) == "table") then
        return true
      end
      kong.log.err("Error trigger_condition configruation, " .. "path: " .. path .. " redis_key: " .. cfg.redis_key)
      return falsek
    end
  else
    -- trigger condition is disabled
    return false
  end
end

function xnor(a,b)
  if a == b then return true else return false end
end

function plugin:access(config)
  plugin.super.access(self)

  local debug = config.debug
  local err_code = config.err_code or 426
  local err_msg = config.err_msg or "Too Many Requests"

  -- get per url config object
  local path = kong.request.get_path()

  if nil ~= path then
    path = string.gsub(path, "//", "/")
  end

  local redis_backoff_count = config.redis_backoff_count or 10
  local redis_backoff_period = (config.redis_backoff_period or 300) * 1000
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
  local pool_size = config.pool_size or 30
  local backlog = config.backlog or 100
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
      return
    end
  end
  if nil ~= redis_auth and string.len(redis_auth) > 0 then
    ok, err = rd:auth(redis_auth)
    if not ok then 
      kong.log.err("Error authenticating to Redis: " .. tostring(err))
      return
    end
  end

  for i, cfg in ipairs(cfgList) do
    local redis_key = substituteVariables(cfg.redis_key, path, kong.request.get_method(), kong.client.get_forwarded_ip(), kong.request)
    if debug then
      kong.log.debug("Rate limit redis_key: " .. path .. " -> " .. redis_key)
    end
    local validVerification = true
    -- the additonal part for trigger condition
    if triggerConditionValid(cfg, path) then
      local triggerSide = cfg.trigger_values ~= nil or cfg.not_trigger_values == nil -- negation logic flipping for not_trigger_values
      if triggerSide then
       validVerification = false
      end
      local triggerValues = cfg.trigger_values or cfg.not_trigger_values
      local condResolved = false
      for _ , triggerValue in pairs(triggerValues) do
        local resolvedConditionVar = substituteVariables( cfg.trigger_condition, path, kong.request.get_method(), kong.client.get_forwarded_ip(), kong.request)
        if not condResolved then
          if (resolvedConditionVar == triggerValue) then
            if triggerSide then -- case 'trigger_values'
              -- Enable the rate limit trigger for either one match 'trigger_values'
              validVerification = true
            else
              -- Disable the rate limit trigger for either one match 'not_trigger_values'
              validVerification = false
            end
            condResolved = true
          end
        end
      end
    end
    if validVerification then
      -- rate limitation counting logic
      local count
      count, err = rd:incr(redis_key)
      if type(count) ~= "number" then
        kong.log.err("Error calling redis incr:" .. tostring(count) .. ", " .. tostring(err))
      else
        if count == 1 then
          rd:expire(redis_key, cfg.window or 1)
        elseif count > cfg.limit then
          -- there is a race condition, that if somehow, we failed to call rd:expire(), then the key will stay here forever
          -- therefore, we need to periodically check for the ttl, if unexpected condition detected, we will delete the key
          if (count - cfg.limit) % 10 == 0 then
            local ttl = rd:ttl(redis_key)
            if ttl < 0 then
              kong.log.err("Redis key ttl is less than 0, will delete it: " .. redis_key)
              rd:del(redis_key)
            end
          end
          -- if the cfg block defined err_code and err_msg, use it, otherwise, use global err_code and err_msg
          kong.response.exit(cfg.err_code or err_code, cfg.err_msg or err_msg)
        end
      end

    end
  end
end

-- set the plugin priority, which determines plugin execution order
plugin.PRIORITY = 840

-- return our plugin object
return plugin
