# Flexible Rate Limit for Kong API Gateway

The following are global config parameters

| Parameter | Parameter Type | Description |
|-----------|:---------------|:------------|
| `redis_host` | `string` | `required`, the redis host to connect to |
| `redis_port` | `number` | the redis port, default is `6379` |
| `redis_auth` | `string` | the redis password, Redis authentication is used only if defined |
| `redis_ssl` | `boolean` | if true, use SSL to connect to redis (defaults to false) |
| `redis_backoff_count` | `number` | if the plugin can't connect to Redis (probably Redis is down) for too many times, the plugin will be backoff for a period of time, this is the number of counts to activate the backoff, default value is 10 |
| `redis_backoff_period` | `number` | if the plugin can't connect to Redis (probably Redis is down) for too many times, the plugin will be backoff for a period of time, this is the time period of the backoff, value in seconds, default value is 300 (5min) |
| `debug` | `boolean` | if true, will return rejection reason in HTTP response body |
| `timeout` | `number` | redis/socket operation timeout, value in millisecond |
| `err_code` | `number` | if set, rejected requests will be in this code, otherwise, rejected requets will be HTTP 426 |
| `err_msg` | `string` | if set, rejected requests will be in this code, otherwise, rejected msg will be `Too Many Requests` |

Per each url path and for each HTTP method, you can specify an array with the following fields

| Field name | Field type | Description |
|-----------|:-----------------|:------------|
| `redis_key` | `string` | Detail description see below |
| `window` | `number` | the window of the rate limit in milliseconds (for backward compatibility, if the value is less-than-or-equals to 10, it is considered as seconds, this dirty trick will be removed in the future) |
| `limit` | `number` | the number of max request per window |
| `trigger_condition` | `number` | the variable for verifying the trigger of that rate limit rule |
| `trigger_values` | `number` | the matching value of `trigger_condition` for trigger that rate limit rule |
| `not_trigger_values` | `number` | the matching value of `not_trigger_values` for NOT trigger that rate limit rule |

`redis_key` and `trigger_condition` are strings supporting the following variable substitutions
- `${method}`: the request method
- `${url}`: the url path, does NOT include querystring
- `${ip}`: the result of `kong.client.get_forwarded_ip()`
- `${header.xxx}`: the result of `kong.request.get_header(xxx)`, note `-` is supported
- `${query.xxx}`: the result of `kong.request.get_query()[xxx]`
- `${body.xxx}`: the result of `kong.request.get_body()[xxx]`
- `${_0.xxx}`: a special function to split `xxx` and get the first part
- `${_1.xxx}`: a special function to split `xxx` and get the second part

# Environment Variables

Except writing `redis_*` in the config, the system also supports reading Redis auth string via the environment variable `FLEXIBLE_RATE_LIMIT_*`. 

- `redis_host` -> `FLEXIBLE_RATE_LIMIT_REDIS_HOST`
- `redis_port` -> `FLEXIBLE_RATE_LIMIT_REDIS_PORT`
- `redis_auth` -> `FLEXIBLE_RATE_LIMIT_REDIS_AUTH`
- `redis_ssl` -> `FLEXIBLE_RATE_LIMIT_REDIS_SSL`

However, in order for this to work, you also have to add the following line in `nginx.config`

```text
env FLEXIBLE_RATE_LIMIT_REDIS_HOST;
env FLEXIBLE_RATE_LIMIT_REDIS_PORT;
env FLEXIBLE_RATE_LIMIT_REDIS_AUTH;
env FLEXIBLE_RATE_LIMIT_REDIS_SSL;
```

Also see [HERE](https://github.com/openresty/lua-nginx-module#system-environment-variable-support)

# Configuration

There are two types of paths in the config, `exact_match` and `pattern_match`, we currently only support `exact_match`

```js
"/path1/path2": {
    "GET": [
        {
            "redis_key": "rate_limit2:${url}:${header.My-Real-IP}",
            "window": 50,
            "limit": 10,
            "trigger_condition": "${header.My-Real-IP}",
            "trigger_values": ["192.168.1.101","192.168.1.102"]
        },
        {
            "redis_key": "rate_limit1:${url}:${header.My-Real-IP}",
            "window": 10,
            "limit": 10,
            "trigger_condition": "${header.My-Real-IP",
            "not_trigger_values": ["192.168.1.101","192.168.1.102"]
        },
        {
            "redis_key": "rate_limit2:${url}:${header.My-Real-IP}",
            "window": 900,
            "limit": 100
        }
    ],
    "POST": [
        ...
    ]
}
```
In the above setting, the path `/path1/path2` `GET` will be rate limited with 
- 50 calls in 10 seconds if the `My-Real-IP` EQUALS to IP "192.168.1.101" OR "192.168.1.102"
- 10 calls in 10 seconds if the `My-Real-IP` DOES NOT EQUAL to IP "192.168.1.101" OR "192.168.1.102"
- 100 calls in 15 minutes

And the limit will be per IP (assuming `My-Real-IP` is the real ip)

Note
- the prefix `rate_limit1` and `rate_limit2`, should be different, otherwise, they will use the same Redis key
- to match any HTTP method, use `*`

# Testing the plugin

The plugin can only be tested in [Kong Vagrant](https://github.com/Kong/kong-vagrant) environment. 

In `Kong Vagrant` README file, they mention

```sh
$ git clone https://github.com/Kong/kong-plugin
..
$ export KONG_PLUGINS=bundled,myplugin
```

Change that line to 
```sh
$ git clone https://github.com/samngms/kong-plugin-request-firewall kong-plugin
..
$ export KONG_PLUGINS=bundled,kong-plugin-request-firewall
```

Note, the `export=...` is not needed unless you need to *start* the real Kong (not just run in test mode).

This is needed because the Vagrant script hardcoded the path `kong-plugin`

Once everything is ready, you can run the following command
```sh
$ # the following starts the docker
$ docker-compose up -d 
$ vagrant up
$ vagrant ssh
... inside vagrant ...
$ cd /kong
$ bin/busted -v -o gtest /kong-plugin/spec
```

All the Kong server logs can be found in `/kong/servroot/logs`


# About luarocks

If you use `brew install kong`, it actually install both `kong` and `openresty`, with `luarocks` installed under `openresty`

Therefore, when you run `luarocks`, you can see there are two trees
- `<your_home>/.luarocks`
- `<path_to_openresty>/luarocks`

However, the rock should be installed inside `kong`, not inside `openresty`

# Installation

To install the plugin into `kong`

```shell script
# luarocks --tree=<path_to_kong> install
```

For example, `path_to_kong` on my machine is `/usr/local/Cellar/kong/1.2.2/`

# Uninstall

```shell script
# luarocks --tree=<path_to_kong> remove kong-plugin-flexible-rate-limit
```

# Configuration

Kong Plugin Admin API can be in Json

```http request
POST /routes/c63128b9-7e71-47ff-80e7-dbea406d06fc/plugins HTTP/1.1
Host: localhost:8001
User-Agent: burp/1.0
Accept: */*
Content-Type: application/json
Content-Length: 377

{"name":"flexible-rate-limit","config":{{"err_code":429,"redis_host":"localhost","exact_match":{"/path1/path2":{"GET":[{"redis_key":"rate_limit1:${url}:${header.My-Real-IP}","window":10,"limit":10},{"redis_key":"rate_limit2:${url}:${header.My-Real-IP}","window":900,"limit":100}]}}}}}
```



