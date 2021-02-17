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
        graphql_request_cost = 200,
        graphql_match = {
          ["/post"] = {
            ["query"] = {
              ["you"] = {
                [1] = {
                  redis_key = "you-${graphql.root}-${graphql.type}",
                  window = 1000,
                  limit = 5,
                  cost = 100 
                }
              },
              ["viewToken"] = {
                [1] = {
                  redis_key = "viewToken-${graphql.root}-${graphql.type}",
                  window = 1000,
                  limit = 5,
                  cost = 100 
                }
              },
              ["me2"] = {
                [1] = {
                  redis_key = "meme-${graphql.root}-${graphql.type}",
                  window = 1000,
                  limit = 5,
                  cost = 1
                }
              },
              ["me3"] = {
                [1] = {
                  redis_key = "mememe-${graphql.root}-${graphql.type}",
                  window = 1000,
                  limit = 5,
                  cost = 1
                }
              },
              ["testinput"] = {
                [1] = {
                  redis_key = "test-input",
                  window = 1000,
                  limit = 5,
                  cost = 1
                }
              }
            },
            ["mutation"] = {
              ["deleteToken"] = {
                [1] = {
                  redis_key = "${graphql.root}-${graphql.type}-${graphql.root.input.accountID}",
                  window = 1000,
                  limit = 5,
                  cost = 1
                }
              }
            },
            ["subscription"] = {
              ["subscribeMe"] = {
                [1] = {
                  redis_key = "subscribe-Me${graphql.root}-${graphql.type}-${graphql.depth}",
                  window = 1000,
                  limit = 5, 
                  cost = 1
                }
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

      it("10 viewToken query requests", function()
        for i = 1, 10, 1 do
          local r = assert(client:send {
            method = "POST",
            path = "/post",
            headers = {
              host = "postman-echo.com",
              ["Content-Type"] = "application/json"
            },
            body = [[
                {"query":"query viewToken { viewToken { token } }",
                  "variables": {"email":"test1"}
                }
                ]]
          })
          if i <= 5 then
            assert.response(r).has.status(200)
          else
            assert.response(r).has.status(488)
          end
        end
        socket.sleep(1)
      end)

      it("1 request with 4 viewToken queries (over configured maximum cost)", function()
        local r = assert(client:send {
          method = "POST",
          path = "/post",
          headers = {
            host = "postman-echo.com",
            ["Content-Type"] = "application/json"
          },
          body = [[
            {"query":"query viewToken { viewToken { token } } \n query viewToken { viewToken { token } } \n
            query viewToken { viewToken { token } } \n query viewToken { viewToken { token } }",
              "variables": {"email":"test1"}
            }
            ]]
        })
        assert.response(r).has.status(488)
        socket.sleep(1)
      end)

      it("10 deleteToken mutations, with variable", function()
        for i = 1, 10, 1 do
          local r = assert(client:send {
            method = "POST",
            path = "/post",
            headers = {
              host = "postman-echo.com",
              ["Content-Type"] = "application/json"
            },
            body = [[
              {"query":"mutation deleteToken($accountID: ID!) { deleteToken (accountID: $id) { token } }",
                "variables": {"id":123}
              }  
            ]]
          })
          if i <= 5 then
            assert.response(r).has.status(200)
          else
            assert.response(r).has.status(488)
          end
        end
        socket.sleep(1)
      end)

      it("2 viewToken query in 1 request (within cost limit)", function()

        local r = assert(client:send {
          method = "POST",
          path = "/post",
          headers = {
            host = "postman-echo.com",
            ["Content-Type"] = "application/json"
          },
          body = [[
            {"query":"query viewToken { viewToken { token } } \n query viewToken { viewToken { token } } "
          }
          ]]
        })
        assert.response(r).has.status(200)
        socket.sleep(1)
      end)

      it("no match", function()
          local r = assert(client:send {
            method = "POST",
            path = "/post",
            headers = {
              host = "postman-echo.com",
              ["Content-Type"] = "application/json"
            },
            body = 'no query'
          })
          assert.response(r).has.status(200)
        socket.sleep(1)
      end)

    end)

  end)
end
