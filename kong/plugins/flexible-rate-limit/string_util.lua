local function resolve(key, url, method, ip, request) 
  if key == "url" then
    return url
  elseif key == "ip" then
    return ip
  elseif key == "method" then
    return method
  else
    local idx = key:find(".", 1, true)
    if not idx then
        return key
    end
    local prefix = key:sub(1, idx-1)
    local suffix = key:sub(idx+1)
    if prefix == "_0" or prefix == "_1" then
      local tmp = resolve(suffix, url, method, ip, request) 
      local idx2 = tmp:find("_", 1, true)
      if not idx2 then
        return tmp
      else
        if prefix == "_0" then
          return tmp:sub(1, idx2-1)
        else 
          return tmp:sub(idx2+1)
        end
      end
    elseif prefix == "header" then
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
end

local function interpolate(template, url, method, ip, request) 
    local output = template:gsub("%$%{[^%}]+%}", function(key) 
        local key2 = key:sub(3, -2)
        return resolve(key2, url, method, ip, request)
    end)
    return output
  end


return {
    interpolate = interpolate
}