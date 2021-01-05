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
      local requestBody = request.get_raw_body()
      local gqlTable
  
      -- seems a single GraphQL document can only
      -- contain queries, mutations or subscriptions but cannot
      -- combine multiple types
      -- this part is also a bit flawed, it will get the first match, then try if it works

      -- support ${graphql.type} (to return either query, mutation or subscription)
      -- our doc may need to explain that if there is query and mutation, it will only select the first type
  
      if nil ~= requestBody:find("query") then
        if suffix == "type" then return "query" end
        gqlTable = requestBody:gmatch("query.*%{.*}")
      elseif nil ~= requestBody:find("mutation") then
        if suffix == "type" then return "mutation" end
        gqlTable = requestBody:gmatch("mutation.*%{.*}")
      elseif nil ~= requestBody:find("subscription") then
        if suffix == "type" then return "subscription" end
        gqlTable = requestBody:gmatch("subscription.*%{.*}")
      end

      if nil ~= gqlTable then
        local parser = GqlParser:new()
        for gqlOperation in gqlTable do
          local gqlObject = parser:parse(gqlOperation)
          -- support ${graphql.depth}
          if suffix == "depth" then return gqlObject:nestDepth() end
          if nil ~= gqlObject then
            -- still keeping this loop, but will only take the first fields, may add further functionality later
            for _, gqlType in pairs(gqlObject:listOps()) do
              for _, gqlName in pairs(gqlType:getRootFields()) do
                -- support  ${graphql.name}, returns the first root name
                if suffix == "name" then return gqlName["name"] end
                local rootArguments = gqlName:resolveArgument({})
                -- again this loop only works for the first argument for now
                for inputKey, inputTable in pairs(rootArguments) do
                  -- support ${graphql.arg_name} for the first input name 
                  if suffix == "arg_name" then return inputKey end 
                  for inputTableKey, inputTableValue in pairs(inputTable) do
                    -- support ${graphql.arg_value} which is the first value of the input
                    if suffix == "arg_value" then return tostring(inputTableValue) end
                    return key -- just putting this return here for now to save computing resources if no match
                  end
                end
              end
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