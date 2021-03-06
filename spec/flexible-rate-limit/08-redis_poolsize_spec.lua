local helpers = require "spec.helpers"
local redis = require("resty.redis")
local socket = require 'socket'

describe("Testing redis pool_size and backlog", function()
  it("closing redis connection properly", function()       
    for i=1, 20, 1 do    
      local rd = redis:new()
      rd:set_timeout(200)
      local ok, err = rd:connect(helpers.redis_host, 6379, {pool_size = 5, backlog = 5})
      assert.are.equal(ok, 1)
      -- close will really close the underlying socket connection
      rd:close()
    end
  end)

  it("NOT closing redis connection", function()       
    for i=1, 20, 1 do    
      local rd = redis:new()
      rd:set_timeout(200)
      local ok, err = rd:connect(helpers.redis_host, 6379, {pool_size = 5, backlog = 5})
      -- if not closing connection after use, only 5 connection can be made
      if i<=5 then
        assert.are.equal(ok, 1)
      else
        assert.are_not.equal(ok, 1)
      end
    end
  end)

  it("set_keepalive() instead of close()", function()       
    for i=1, 20, 1 do    
      local rd = redis:new()
      rd:set_timeout(200)
      local ok, err = rd:connect(helpers.redis_host, 6379, {pool_size = 5, backlog = 5})
      -- set_keepalive() will set the connection to closed state
      -- but the underlying socket connection is still active
      rd:set_keepalive()
    end
  end) 

end)
