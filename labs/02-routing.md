# Lab 02 — Routing

Routing is how one hostname and one port become many services. Two things
decide it: which `location` block wins, and what path the backend ends up
seeing.

## Step 1 — location precedence is not top-to-bottom

This surprises almost everyone. nginx evaluates in this order:

1. exact match — `location = /path`
2. longest prefix marked `^~` — `location ^~ /path/`
3. **first matching regex, in file order** — `location ~ /path`
4. longest plain prefix — `location /path`

Run these four and predict each before you press enter:

```bash
curl -s http://localhost:8080/match/exact
curl -s http://localhost:8080/match/stop/re
curl -s http://localhost:8080/match/abc/re
curl -s http://localhost:8080/match/anything
```

Results:

| Request | Wins | Why |
|---|---|---|
| `/match/exact` | exact | `=` beats everything, checked first |
| `/match/stop/re` | `^~` prefix | `^~` means "found a prefix, stop looking for regexes" |
| `/match/abc/re` | regex | regex beats plain prefix even though `/match/` is also a match |
| `/match/anything` | plain prefix | nothing else matched |

The third row is the one that bites in production. Someone adds an innocuous
regex location for `\.(jpg|png)$` and it silently steals traffic from a prefix
block defined 200 lines further down. Note also that regexes are tried **in the
order written**, so among regexes, position does matter — it's only the
categories that are ranked.

## Step 2 — the trailing slash on proxy_pass

This one line decides what path your backend receives:

```nginx
proxy_pass http://echo_pool/;   # with slash: strip the location prefix
proxy_pass http://echo_pool;    # without:   pass the whole path through
```

See it:

```bash
curl -s http://localhost:8080/strip/headers   | python3 -c 'import sys,json; print(json.load(sys.stdin)["path"])'
curl -s http://localhost:8080/nostrip/headers | python3 -c 'import sys,json; print(json.load(sys.stdin)["path"])'
```

`/strip/headers` arrives at the backend as `/headers`. `/nostrip/headers`
arrives as `/nostrip/headers`.

Mentally: with a trailing slash you're saying "replace the matched prefix with
this". Without one you're saying "just change the destination host". Neither is
right or wrong — but a backend that has no idea what `/nostrip` is will return
404, and you'll spend an hour blaming the backend.

## Step 3 — try it yourself

Change `/network-chaos/` in `nginx.conf` to drop its trailing slash:

```nginx
proxy_pass http://toxiproxy_pool;
```

Then:

```bash
docker compose exec gateway nginx -t
docker compose restart gateway
curl -si http://localhost:8080/network-chaos/get | head -1
```

404 — go-httpbin has no `/network-chaos/get` route. Put the slash back and it's a 200
again. This is the fastest possible demonstration of why gateway configs get a
reputation for being fiddly.

## Step 4 — rewriting paths

Sometimes you want a public path that doesn't match the backend's path at all —
your API is versioned but the service isn't. Add this to the server block:

```nginx
location /api/v1/balanced/ {
    include /etc/nginx/snippets/proxy-headers.conf;
    rewrite ^/api/v1/balanced/(.*)$ /$1 break;
    proxy_pass http://echo_pool;
}
```

```bash
docker compose restart gateway
curl -s http://localhost:8080/api/v1/balanced/headers \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["path"])'
```

The backend sees `/headers`. Note `break` — it means "stop rewriting and use
this result". Without it, nginx re-runs location matching against the new path
and you can loop.

This is the mechanism behind API versioning: `/api/v1/` and `/api/v2/` can point
at completely different backends while both rewriting to the same internal path,
which is how you run two versions of a service side by side during a migration.

## Step 5 — routing on something other than path

Path is the obvious key, but a gateway can route on anything in the request.
Host is the classic:

```nginx
server {
    listen 80;
    server_name api.lab.local;    # matched against the Host header
    ...
}
```

Test it without touching DNS by lying about the Host header:

```bash
curl -s -H 'Host: api.lab.local' http://localhost:8080/balanced/
```

That's virtual hosting, and it's why lab 1's point about preserving `Host`
matters so much — the header *is* the routing key. You can also route on
headers or cookies using `map`, which is how canary deploys and A/B tests get
implemented at the gateway:

```nginx
map $http_x_canary $backend_pool {
    default  "echo_pool";
    "true"   "canary_pool";
}
```

## What you learned

- Location precedence is by category, not file order — and regex outranks plain
  prefixes.
- The trailing slash on `proxy_pass` rewrites the upstream path.
- `rewrite ... break` decouples your public API shape from your services' shape.
- Any part of the request can be a routing key; path and Host are just the
  common ones.

---

Prev: [01 — what a proxy does](01-what-a-proxy-does.md) · Next: [03 — load balancing](03-load-balancing.md)
