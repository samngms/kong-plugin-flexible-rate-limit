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
        --graphql_endpoints = { "/graphql", "/admin/graphql" },
        graphql_match = {
          ["/post"] = {
            ["query"] = {
              ["me"] = {
                [1] = {
                  redis_key = "me",
                  window = 1000,
                  limit = 5
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

      it("10 requests in 1 batch", function()
        for i = 1, 10, 1 do
          local r = assert(client:send {
            method = "POST",
            path = "/post",
            headers = {
              host = "postman-echo.com",
              ["Content-Type"] = "application/x-www-form-urlencoded"
            },
            --body = "query { me { name } }"
            body = "query { me { name } } \n query { you { name } }"
            -- something like this would break the graphql-parser if passed directly into it.
            -- that's why tried to do pattern match 
            --body = '{"operationName":null,"variables":{"first":10,"filterBy":{}},"query":"query    ($first: Int, $last: Int, $after: String, $before: String, $filterBy: PayoutFilters) {\n  payouts(first: $first, last: $last, after: $after, before: $before, filterBy: $filterBy) {\n    nodes {\n      id\n      status\n      currency\n      amount\n      amountInUsd\n      fee\n      feeInUsd\n      description\n      result\n      merchantId\n      merchantName\n      createdAt\n      updatedAt\n      payoutAccount {\n        id\n        status\n        accountType\n        currency\n        countryCode\n        accountHolder\n        businessAddress\n        iban\n        address\n        __typename\n      }\n      __typename\n    }\n    pageInfo {\n      startCursor\n      endCursor\n      hasNextPage\n      hasPreviousPage\n      __typename\n    }\n    __typename\n  }\n}\n"}'
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
