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

    it("test split function 1", function()       
      local req = MockRequest:new(nil, {}, {name = "1234"}, {})
      local s = util.interpolate("abc:${query.name}:${_0.query.name}:${_1.query.name}", "/path/file", "POST", "12.34.5.6", req)
      assert.are.equal(s, "abc:1234:1234:1234")
    end)

    it("test split function 2", function()       
      local req = MockRequest:new(nil, {}, {name = "12345"}, {})
      local s = util.interpolate("abc:${query.name}:${_0.query.name}:${_1.query.name}", "/path/file", "POST", "12.34.5.6", req)
      assert.are.equal(s, "abc:12345:123:45")
    end)

    it("test split function 3", function()       
      local req = MockRequest:new(nil, {}, {name = "atomwater"}, {})
      local s = util.interpolate("abc:${query.name}:${_0.query.name}:${_1.query.name}", "/path/file", "POST", "12.34.5.6", req)
      assert.are.equal(s, "abc:atomwater:atom:water")
    end)

    it("test split function 4", function()       
      local req = MockRequest:new(nil, {}, {name = "hello_world"}, {})
      local s = util.interpolate("abc:${query.name}:${_0.query.name}:${_1.query.name}", "/path/file", "POST", "12.34.5.6", req)
      assert.are.equal(s, "abc:hello_world:hello:world")
    end)

    it("test split function 5", function()       
      -- can handle more than one "_", and case sensitive
      local req = MockRequest:new(nil, {}, {name = "Foo__Bar_"}, {})
      local s = util.interpolate("abc:${query.name}:${_0.query.name}:${_1.query.name}", "/path/file", "POST", "12.34.5.6", req)
      assert.are.equal(s, "abc:Foo__Bar_:Foo:_Bar_")
    end)

    it("test split function 6", function()       
      local req = MockRequest:new(nil, {}, {name = "_Apple"}, {})
      local s = util.interpolate("abc:${query.name}:${_0.query.name}:${_1.query.name}", "/path/file", "POST", "12.34.5.6", req)
      assert.are.equal(s, "abc:_Apple::Apple")
    end)

    it("test split function 7", function()       
      local req = MockRequest:new(nil, {}, {name = "Orange_"}, {})
      local s = util.interpolate("abc:${query.name}:${_0.query.name}:${_1.query.name}", "/path/file", "POST", "12.34.5.6", req)
      assert.are.equal(s, "abc:Orange_:Orange:")
    end)

    it("test split function 8", function()       
      local req = MockRequest:new(nil, {}, {}, {name = {first = "John", last = "Doe"}, age = 20})
      local s = util.interpolate("abc:${body.name.first}:${body.name.last}:${body.age}", "/path/file", "POST", "12.34.5.6", req)
      assert.are.equal(s, "abc:John:Doe:20")
    end)

    it("test split function 9", function()       
      local req = MockRequest:new(nil, {}, {}, {name = {first = {"John", "Peter"}}})
      local s = util.interpolate("abc:${body.name.first}:${body.name.last}", "/path/file", "POST", "12.34.5.6", req)
      assert.are.equal(s, "abc:[\"John\",\"Peter\"]:body.name.last")
    end)

    it("test split function 10", function()       
      local req = MockRequest:new(nil, {}, {}, {name = {first = {"John", "Peter"}}})
      local s = util.interpolate("abc:${body.name}", "/path/file", "POST", "12.34.5.6", req)
      assert.are.equal(s, "abc:{\"first\":[\"John\",\"Peter\"]}")
    end)

  end)
