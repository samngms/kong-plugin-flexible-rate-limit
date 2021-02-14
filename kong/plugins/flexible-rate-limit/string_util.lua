local cjson = require("cjson")
-- load graphql-parser
local GqlParser = require("graphql-parser")

local fourLetters = {usdt = 1, usdc = 1, tusd = 1, dash = 1, link = 1, atom = 1, hedg = 1, iota = 1, doge = 1, qtum = 1, algo = 1, nano = 1}

local function getJson(key, table) 
  if type(table) ~= "table" then
    return nil
  end

  local idx = key:find(".", 1, true)
  if idx then
    local prefix 
    if idx == 1 then
      prefix = ""
    else
      prefix = key:sub(1, idx-1)
    end
    local tmp = table[prefix]
    if tmp then
      if idx == key:len() then
        return tostring(tmp)
      else
        return getJson(key:sub(idx+1), tmp)
      end
    else
      return nil
    end
  else
    return table[key]
  end
end

local function resolve(key, url, method, ip, request, list) 
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
      local underScore = tmp:find("_", 1, true)
      if underScore then
        if prefix == "_0" then
          return tmp:sub(1, underScore-1)
        else 
          return tmp:sub(underScore+1)
        end
      else
        tmp = tmp:lower()
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
      end
    elseif prefix == "header" then
        return request.get_header(suffix) or key
    elseif prefix == "body" then
        local body = request.get_body()
        if nil == body then return key end
        local allInOne = body[suffix]
        if allInOne then
          if type(allInOne) == "table" then
            return cjson.encode(allInOne)
          else
            return allInOne
          end
        else
          local tmp = getJson(suffix, body)
          if type(tmp) == "table" then
            return cjson.encode(tmp)
          else
            return tmp or key
          end
        end
    elseif prefix == "query" then
        local query = request.get_query()
        if nil == query then return key end
        return query[suffix] or key
    elseif prefix == "graphql" then
      if suffix == "type" then return list.gql_type end
      if suffix == "root" then return list.gql_root end
      if suffix == "depth" then return list.gql_depth end

      local subStrings = {}
      local subStringCount = 0
      for subString in key:gmatch("[^%.]+") do
        table.insert(subStrings, subString)
        subStringCount = subStringCount + 1
      end

      -- set up this structure, may be more useful in the future
      -- for now it can resolve only resolve ROOT inputs, but for any graphql.root.input.variable
      if subStrings[subStringCount - 1] == "input" and subStrings[subStringCount - 2] == "root" then
        local configuredInputKey = subStrings[subStringCount]
        for inputKey, inputKeyTable in pairs(list.gql_root_args) do
          for _, inputValue in pairs(inputKeyTable) do
            if inputKey == configuredInputKey then
              return inputValue
            end
          end
        end
      end

      return key
    else
      return key
    end
  end
end

-- we don't use gsub because it causes the "yield" problem along if I use redis:set_keepalive()
-- coroutine: runtime error: attempt to yield across C-call boundary
local function interpolate(template, url, method, ip, request, list) 
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
        output = output .. resolve(key, url, method, ip, request, list)
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