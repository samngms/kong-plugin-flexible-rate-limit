local fourLetters = {usdt = 1, usdc = 1, tusd = 1, dash = 1, link = 1, atom = 1, hedg = 1, iota = 1, doge = 1, qtum = 1, algo = 1, nano = 1}

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
      local tmp = resolve(suffix, url, method, ip, request):lower()
      if tmp:len() > 4 then
        local p1 = tmp:sub(1, 4)
        if fourLetters[p1] == 1 then
          if prefix == "_0" then 
            return p1 
          else
            return tmp:sub(5)
          end
        else
          if prefix == "_0" then
            return tmp:sub(1, 3)
          else
            return tmp:sub(4)
          end
        end
      else
        return tmp
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

-- we don't use gsub because it causes the "yield" problem along if I use redis:set_keepalive()
-- coroutine: runtime error: attempt to yield across C-call boundary
local function interpolate(template, url, method, ip, request) 
  local start = 1
  local output = ""
  while(true) do
    local idx = string.find(template, "${", start, true)
    local _break = true
    if idx then
      local _end = string.find(template, "}", idx+2, true)
      if _end then
        _break = false
        output = output .. string.sub(template, start, idx-1)
        local key = string.sub(template, idx+2, _end-1)
        output = output .. resolve(key, url, method, ip, request)
        start = _end + 1
      end
    end
    if _break then 
      if start == 1 then
        output = start
      else
        output = output .. string.sub(template, start)
      end
      break 
    end
  end
  return output
end


return {
    interpolate = interpolate
}