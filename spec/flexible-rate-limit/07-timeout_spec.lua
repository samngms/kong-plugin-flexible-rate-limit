local helpers = require "spec.helpers"
local version = require("version").version or require("version")
local socket = require 'socket'

local PLUGIN_NAME = "flexible-rate-limit"
local KONG_VERSION
do
  local _, _, std_out = assert(helpers.kong_exec("version"))
  if std_out:find("[Ee]nterprise") then
    std_out = std_out:gsub("%-", ".")
  end
  std_out = std_out:match("(%d[%d%.]+%d)")
  KONG_VERSION = version(std_out)
end

for _, strategy in helpers.each_strategy() do
  describe(PLUGIN_NAME .. ": (basic URL tests) [#" .. strategy .. "]", function()
    local client

    lazy_setup(function()
      local bp, route1
      local myconfig = {
        redis_host = "12.34.56.78", -- this ip is wrong
        redis_port = 1234, -- this port number is wrong
        debug = true,
        err_code = 488,
        timeout = 100, -- 100ms
        redis_backoff_count = 20,
        redis_backoff_period = 5000, -- 5000ms
        exact_match = {
          ["/get"] = {
            ["*"] = {
              [1] = {
                redis_key = "hello:${query.api_key}",
                window = 1000,
                limit = 5
              }
            }
          }
        }
      }

      if KONG_VERSION >= version("0.35.0") or
         KONG_VERSION == version("0.15.0") then
        --
        -- Kong version 0.15.0/1.0.0+, and
        -- Kong Enterprise 0.35+ new test helpers
        --
        local bp = helpers.get_db_utils(strategy, nil, { PLUGIN_NAME })

        local route1 = bp.routes:insert({
          hosts = { "postman-echo.com" },
        })
        bp.plugins:insert {
          name = PLUGIN_NAME,
          route = { id = route1.id },
          config = myconfig
        }
      else
        --
        -- Kong Enterprise 0.35 older test helpers
        -- Pre Kong version 0.15.0/1.0.0, and
        --
        local bp = helpers.get_db_utils(strategy)

        local route1 = bp.routes:insert({
          hosts = { "postman-echo.com" },
        })
        bp.plugins:insert {
          name = PLUGIN_NAME,
          route_id = route1.id,
          config = myconfig
        }
      end

      -- start kong
      assert(helpers.start_kong({
        -- set the strategy
        database   = strategy,
        -- use the custom test template to create a local mock server
        nginx_conf = "spec/fixtures/custom_nginx.template",
        -- set the config item to make sure our plugin gets loaded
        plugins = "bundled," .. PLUGIN_NAME,  -- since Kong CE 0.14
        custom_plugins = PLUGIN_NAME,         -- pre Kong CE 0.14
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong(nil, true)
    end)

    before_each(function()
      client = helpers.proxy_client()
    end)

    after_each(function()
      if client then client:close() end
    end)


    describe("testing ", function()

      it("Connection timeout is working properly", function()
        local time0 = socket.gettime()
        for i = 1, 10, 1 do
          local r = assert(client:send {
            method = "GET",
            path = "/get",
            headers = {
              host = "postman-echo.com",
              ["Content-Type"] = "application/x-www-form-urlencoded"
            },
            query = "api_key=1234"
          })
          -- if it can't contact redis, it should pass-thru
          assert.response(r).has.status(200)
        end
        -- default timeout is 30s, and in here the setting is 100ms
        -- 5 requests, should be larger > 1000ms and <= 1500ms
        local diffTime = socket.gettime() - time0
        assert.is_true(diffTime >= 1 and diffTime <= (2+1))
      end)

      it("Backoff counter and period is working properly", function()
        local time0 = socket.gettime()
        for i = 1, 100, 1 do
          local r = assert(client:send {
            method = "GET",
            path = "/get",
            headers = {
              host = "postman-echo.com",
              ["Content-Type"] = "application/x-www-form-urlencoded"
            },
            query = "api_key=1234"
          })
          -- if it can't contact redis, it should pass-thru
          assert.response(r).has.status(200)
        end
        -- backoff_count is 20, the previous test has 10 request
        -- therefore, in here, 90 should pass-thru without any time delay
        -- therefore, the diffTime should less than 1000ms 
        -- if the backoff_(count|period) is not working, then the total delay would be 10,000ms
        local diffTime = socket.gettime() - time0
        assert.is_true(diffTime <= (2+1))
      end)

      it("Backoff resume to normal after backoff period", function()
        -- we are sure after the previous test, the system is now in backoff state
        socket.sleep(5)
        -- after sleep for 10s, backoff time expired
        local time0 = socket.gettime()
        for i = 1, 10, 1 do
          local r = assert(client:send {
            method = "GET",
            path = "/get",
            headers = {
              host = "postman-echo.com",
              ["Content-Type"] = "application/x-www-form-urlencoded"
            },
            query = "api_key=1234"
          })
          -- if it can't contact redis, it should pass-thru
          assert.response(r).has.status(200)
        end
        local diffTime = socket.gettime() - time0
        assert.is_true(diffTime >= 1)
      end)

    end)

  end)
end
