# Flexible Rate Limit for Kong API Gateway

The following are global config parameters

| Parameter | Parameter Type | Description |
|-----------|:---------------|:------------|
| `redis_host` | `string` | `required`, the redis host to connect to |
| `redis_port` | `number` | the redis port, default is `6379` |
| `redis_auth` | `string` | the redis password, use only if defined |
| `debug` | `boolean` | if true, will return rejection reason in HTTP response body |
| `err_code` | `number` | if set, rejected requests will be in this code, otherwise, rejected requets will be HTTP 426 |
| `err_msg` | `string` | if set, rejected requests will be in this code, otherwise, rejected msg will be `Too Many Requests` |

Per each url path, you can specify an array with the following fields

| Field name | Field type | Description |
|-----------|:-----------------|:------------|
| `redis_key` | `string` | Detail description see below |
| `window` | `number` | the window of the rate limit in seconds |
| `count` | `number` | the number of max request per window |

`redis_key` is a string which supports the following variable substitutions
- `${url}`: the url path
- `${ip}`: the result of `kong.client.get_forwarded_ip()`
- `${header.xxx}`: the result of `kong.request.get_header(xxx)`, note `-` is supported
- `${query.xxx}`: the result of `kong.request.get_query()[xxx]`
- `${post.xxx}`: the result of `kong.request.get_body()[xxx]`


# Configuration

There are two types of paths in the config, `exact_match` and `pattern_match`, we currently only support `exact_match`

```js
"/path1/path2": [
    {
        "redis_key": "rate_limit1:${url}:${header.My-Real-IP}",
        "window": 10,
        "count": 10
    },
    {
        "redis_key": "rate_limit2:${url}:${header.My-Real-IP}",
        "window": 900,
        "count": 100
    }
]
```
In the above setting, the path `/path1/path2` will be rate limited with 
- 10 calls in 10 seconds
- 100 calls in 15 minutes

And the limit will be per IP (assuming `My-Real-IP` is the real ip)

Note, the prefix `rate_limit1` and `rate_limit2`, should be different, otherwise, they will use the same Redis key


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
# luarocks --tree=<path_to_kong> remove kong-plugin-request-firewall
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

{"name":"flexible-rate-limit","config":{"query":[{"name": "fullname", "type":"string", "required":false, "validation":"abc"},{"name": "age", "type":"number", "required":false, "validation":"01"}],"body":[{"name":"manager","type":"string"},{"name":"salary","type":"number"}],"class_ref":{"name":"helloclass","fields":[{"name":"id","type":"number"},{"name":"date","type":"string"}]}}}
```



