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
        redis_host = helpers.redis_host,
        redis_port = 6379,
        debug = true,
        err_code = 488,
        exact_match = {
          ["/get"] = {
            ["*"] = {
              [1] = {
                redis_key = "1s:${header.My-IP}",
                window = 1000,
                limit = 10,
                trigger_condition = "${header.My-IP}",
                trigger_values = {
                  [1] = "192.168.1.101",
                  [2] = "192.168.1.102",
                }
              },
              [2] = {
                redis_key = "2s:${header.My-IP}",
                window = 1000,
                limit = 5,
                trigger_condition = "${header.My-IP}",
                not_trigger_values = {
                  [1] = "192.168.1.101",
                  [2] = "192.168.1.102",
                  [3] = "192.168.1.103",
                }
              },
              [3] = {
                redis_key = "3s:${post.api_key}",
                window = 1000,
                limit = 15
              },
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


    describe("testing", function()
      it("Special limit rate for `trigger_values` and bypass the rules of `not_trigger_values`", function()
        for i = 1, 20, 1 do
          local ip =  "192.168.1.101"
          local r = assert(client:send {
            method = "GET",
            path = "/get",
            headers = {
              host = "postman-echo.com",
              ["Content-Type"] = "application/x-www-form-urlencoded",
              ["My-IP"] = ip
            },
            query = "api_key=1234"
          })
          if i <= 10 then
            assert.response(r).has.status(200)
          else
            assert.response(r).has.status(488)
          end
        end
        socket.sleep(1)
      end)

      it("Bypass rules for `not_trigger_values`", function()
        for i = 1, 20, 1 do
          local ip =  "192.168.1.103"
          local r = assert(client:send {
            method = "GET",
            path = "/get",
            headers = {
              host = "postman-echo.com",
              ["Content-Type"] = "application/x-www-form-urlencoded",
              ["My-IP"] = ip
            },
            query = "api_key=1234"
          })
          if i <= 15 then
            assert.response(r).has.status(200)
          else
            assert.response(r).has.status(488)
          end
        end
        socket.sleep(1)
      end)

      it("effective rules for `not_trigger_values`", function()
        for i = 1, 10, 1 do
          local ip =  "192.168.1.104"
          local r = assert(client:send {
            method = "GET",
            path = "/get",
            headers = {
              host = "postman-echo.com",
              ["Content-Type"] = "application/x-www-form-urlencoded",
              ["My-IP"] = ip
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
    end)

  end)
end
