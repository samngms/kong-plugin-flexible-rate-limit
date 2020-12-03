local typedefs = require "kong.db.schema.typedefs"

local GQL_ROOT_TYPES = {
  "query",
  "mutation",
  "subscription"
}

return {
  name = "flexible-rate-limit",
  fields = {
    { consumer = typedefs.no_consumer },
    { config = {
      type = "record",
      fields = {
        { err_code = { type = "number" } },
        { err_msg = { type = "string" } },
        { debug = { type = "boolean", default = false } },
        { redis_host = { type = "string" } },
        { redis_port = { type = "number" } },
        { redis_auth = { type = "string" } },
        { redis_ssl = { type = "boolean" } },
        { redis_backoff_count = { type = "number"} },
        { redis_backoff_period = { type = "number"} },
        { pool_size = { type = "number" } },
        { backlog = { type = "number" } },
        { timeout = { type = "number" } },
        { graphql_endpoints = { type = "array", elements = { type = "string" } } },
        { exact_match = {
          type = "map",
          -- the key is the path of the url
          keys = {
            type = "string"
          },
          values = {
            -- the next key is http method
            type = "map",
            keys = {
              type = "string"
            },
            values = {
              type = "array",
              elements = {
                type = "record",
                fields = {
                  { err_code = { type = "number" } },
                  { err_msg = { type = "string" } },
                  { redis_key = { type = "string", required = true } },
                  { window = { type = "number", default = 1 } },
                  { limit = { type = "number", required = true } },
                  { trigger_condition = { type = "string" } },
                  { trigger_values = { type = "array" , elements = { type = "string" } } },
                  { not_trigger_values = { type = "array" , elements = { type = "string" } } }
                }
              }
            }              
          }
        }},
        { pattern_match = {
          type = "map",
          -- the key is the path of the url
          keys = {
            type = "string"
          },
          values = {
            -- the next key is http method
            type = "map",
            keys = {
              type = "string"
            },
            values = {
              type = "array",
              elements = {
                type = "record",
                fields = {
                  { err_code = { type = "number" } },
                  { err_msg = { type = "string" } },
                  { redis_key = { type = "string", required = true } },
                  { window = { type = "number", default = 1 } },
                  { limit = { type = "number", required = true } },
                }
              }
            }              
          }
        }},
        { graphql_match = {
          type = "map",
          -- first key is the GraphQL root field
          keys = {
            type = "string"
          },
          values = {
            type = "map",
            -- second key is the GraphQL root type, defaults defined in GQL_ROOT_TYPES
            keys = {
              type = "string",
              one_of = GQL_ROOT_TYPES, --seems not to work yet in test code
            },
            values = {
              type = "array",
              elements = {
                type = "record",
                fields = {
                  { err_code = { type = "number" } },
                  { err_msg = { type = "string" } },
                  { redis_key = { type = "string", required = true } },
                  { window = { type = "number", default = 1 } },
                  { limit = { type = "number", required = true } },
                }
              }
            }
          }
        }}
      }
    }}
  }
}
