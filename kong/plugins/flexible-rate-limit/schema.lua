local typedefs = require "kong.db.schema.typedefs"

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
        { redis_host = { type = "string", required = true } },
        { redis_port = { type = "number" } },
        { redis_auth = { type = "string" } },
        { pool_size = { type = "number" } },
        { backlog = { type = "number" } },
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
        }}
      }
    }}
  }
}
