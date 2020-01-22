local util = require("kong.plugins.flexible-rate-limit.string_util")

MockRequest = { }

function MockRequest:new (o, header, query, body)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  self.get_header = function(name) 
    if nil == header then
      return nil
    else
      return header[name]
    end
  end
  self.get_query = function() return query end
  self.get_body = function() return body end
  return o
end

describe("Testing string interpolation", function()
    it("simple test", function()       
      local s = util.interpolate("abc:${url}:${method}:${ip}", "/path/file", "POST", "12.34.5.6", nil)
      assert.are.equal(s, "abc:/path/file:POST:12.34.5.6")
    end)

    it("test request", function()       
      local req = MockRequest:new(nil, {RealIP = "x.y"}, {name = "sam"}, {age = 10})
      local s = util.interpolate("abc:${header.RealIP}:${query.name}:${body.age}", "/path/file", "POST", "12.34.5.6", req)
      assert.are.equal(s, "abc:x.y:sam:10")
    end)

    it("test _0 and _1", function()       
      local req = MockRequest:new(nil, {RealIP = "x.y"}, {name = "sam_ng"}, {age = 10})
      local s = util.interpolate("abc:${query.name}:${_0.query.name}:${_1.query.name}", "/path/file", "POST", "12.34.5.6", req)
      assert.are.equal(s, "abc:sam_ng:sam:ng")
    end)

    it("test invalid _0 and _1", function()       
      local req = MockRequest:new(nil, {RealIP = "x.y"}, {name = "samng"}, {age = 10})
      local s = util.interpolate("abc:${_0.query.name}:${_1.query.name}", "/path/file", "POST", "12.34.5.6", req)
      assert.are.equal(s, "abc:samng:samng")
    end)

  end)
