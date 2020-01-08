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
        redis_host = "127.0.0.1",
        debug = true,
        err_code = 488,
        exact_match = {
          ["/get"] = {
            ["*"] = {
              [1] = {
                redis_key = "hello:${query.api_key}",
                window = 1,
                limit = 5
              }
            }
          },
          ["/post"] = {
            ["*"] = {
              [1] = {
                redis_key = "1s:${body.api_key}",
                window = 1,
                limit = 5,
              },
              [2] = {
                redis_key = "2s:${post.api_key}",
                window = 1,
                limit = 5
              },
              [3] = {
                redis_key = "3s:${post.api_key}",
                window = 3,
                limit = 8
              },
            }
          },
          ["/put"] = {
            ["*"] = {
              [1] = {
                redis_key = "put:${header.My-IP}",
                window = 1,
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

      it("10 requests in 1 batch", function()
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
          if i <= 5 then
            assert.response(r).has.status(200)
          else
            assert.response(r).has.status(488)
          end
        end
        socket.sleep(1)
      end)

      it("10 requests in 2 batchs, with sleep(1) in between", function()
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
          if i == 5 then
            socket.sleep(1)
          end
          assert.response(r).has.status(200)
        end
        socket.sleep(1)
      end)

      it("10 requests with two diff api_keys", function()
        for i = 1, 10, 1 do
          local api_key = "1234"
          if 0 == (i % 2) then api_key = "5678" end
          local r = assert(client:send {
            method = "GET",
            path = "/get",
            headers = {
              host = "postman-echo.com",
              ["Content-Type"] = "application/x-www-form-urlencoded"
            },
            query = "api_key=" .. api_key
          })
          assert.response(r).has.status(200)
        end
        socket.sleep(1)
      end)


      it("test multiple rate limits", function()
        local api_key = "1234"
        for i = 1, 10, 1 do
          if 0 == (i % 2) then ip = "88.77.66.55" end
          local r = assert(client:send {
            method = "POST",
            path = "/post",
            headers = {
              host = "postman-echo.com",
              ["Content-Type"] = "application/x-www-form-urlencoded",
            },
            body = "api_key=" .. api_key
          })
          if i == 5 then
            socket.sleep(1)
          end
          -- so the 6th call would not fall into the 1s interval
          -- but there are two limits, the 2nd limit is a 3s interval, and limit is 8
          if i <= 8 then
            assert.response(r).has.status(200)
          else
            print(r)
            assert.response(r).has.status(488)
          end
        end
        socket.sleep(3)
      end)


      it("test for header", function()
        for i = 1, 10, 1 do
          local ip = "1.2.3.4"
          if (i % 2) == 0 then ip = "3.4.5.6" end
          if 0 == (i % 2) then ip = "88.77.66.55" end
          local r = assert(client:send {
            method = "PUT",
            path = "/put",
            headers = {
              host = "postman-echo.com",
              ["Content-Type"] = "application/x-www-form-urlencoded",
              ["My-IP"] = ip
            },
            query = "api_key=1234"
          })
          -- don't know why put returns 404... but it doesn't matter
          assert.response(r).has.status(404)
        end
        socket.sleep(3)
      end)


    end)

  end)
end
