-- If you're not sure your plugin is executing, uncomment the line below and restart Kong
-- then it will throw an error which indicates the plugin is being loaded at least.
-- assert(ngx.get_phase() == "timer", "Request Validator CE coming to an end!")

-- Grab pluginname from module name
local plugin_name = ({...})[1]:match("^kong%.plugins%.([^%.]+)")

-- load the base plugin object and create a subclass
local plugin = require("kong.plugins.base_plugin"):extend()

local redis = require("resty.redis")

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
        elseif prefix == "post" then
            local post = request.get_body()
            if nil == post then return key end
            return post[suffix] or key
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
  local redis_ssl = config.redis_ssl or os.getenv("FLEXIBLE_RATE_LIMIT_REDIS_SSL") or false
  local pool_size = config.pool_size or 30
  local backlog = config.backlog or 100
  local ok, err = rd:connect(redis_host, redis_port, {pool_size, backlog, redis_ssl})
  if not ok then
    kong.log.err("Error connecting to Redis: " .. tostring(err))
    return
  end
  if redis_auth then
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

-- set the plugin priority, which determines plugin execution order
plugin.PRIORITY = 840

-- return our plugin object
return plugin
