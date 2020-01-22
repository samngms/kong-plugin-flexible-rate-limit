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

local sock_err_count = 0
local sock_err_time = 0

-- constructor
function plugin:new()
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
      local count
      count, err = rd:incr(redis_key)
      if type(count) ~= "number" then
        kong.log.err("Error calling redis incr:" .. tostring(count) .. ", " .. tostring(err))
      else
        if count == 1 then
          local w = cfg.window or 1
          if w <= 10 then w = w * 1000 end
          rd:pexpire(redis_key, w)
        elseif count > cfg.limit then
          -- there is a race condition, that if somehow, we failed to call rd:pexpire(), then the key will stay here forever
          -- therefore, we need to periodically check for the ttl, if unexpected condition detected, we will delete the key
          if (count - cfg.limit) % 10 == 0 then
            local ttl = rd:pttl(redis_key)
            -- "-2" means the key does not exist, we only want "-1"
            if ttl == -1 then
              kong.log.err("Redis key exists but has no associated expire, will delete it: " .. redis_key)
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
