# Lab 05 — Caching

A cache at the gateway is the cheapest capacity you will ever buy. It's also the
easiest place to serve one user's data to another, so the correctness details
matter more than the performance ones.

## Step 1 — no cache yet

`/cached/` returns `X-Cache-Status` on every response, but caching is off:

```bash
curl -si http://localhost:8080/cached/uuid | grep -iE 'x-cache-status|^HTTP'
curl -s  http://localhost:8080/cached/uuid
curl -s  http://localhost:8080/cached/uuid
```

Status is empty and you get a different UUID each time — every request reached
the backend.

## Step 2 — turn it on

Uncomment in `/cached/`:

```nginx
proxy_cache       lab_cache;
proxy_cache_key   "$scheme$request_method$host$request_uri";
proxy_cache_valid 200 30s;
```

```bash
docker compose exec gateway nginx -t
docker compose restart gateway

curl -si http://localhost:8080/cached/uuid | grep -iE 'x-cache-status|^HTTP'
curl -si http://localhost:8080/cached/uuid | grep -iE 'x-cache-status|^HTTP'
curl -s  http://localhost:8080/cached/uuid
curl -s  http://localhost:8080/cached/uuid
```

`MISS` then `HIT`, and the same UUID twice. In the gateway log, the `HIT` line
has no `upstream=` at all — the request never left the gateway.

The zone was declared once at the top of `nginx.conf`:

```nginx
proxy_cache_path /var/cache/nginx/lab levels=1:2 keys_zone=lab_cache:10m
                 max_size=100m inactive=60m use_temp_path=off;
```

`keys_zone=10m` is shared memory holding the *keys* (~8,000 per MB). `max_size`
is disk for the *bodies*. They're separate limits and you can exhaust either.

## Step 3 — the cache key is a security boundary

Look at the key again:

```nginx
proxy_cache_key "$scheme$request_method$host$request_uri";
```

`Authorization` isn't in it. Neither is any cookie. So if this route served
per-user data, request 1 from Alice would be stored, and request 2 from Bob —
different token, same URL — would be a `HIT` on **Alice's response**.

That's not a hypothetical; it's a recurring class of real breach. Prove the
mechanism:

```bash
curl -si -H 'Authorization: Bearer alice' http://localhost:8080/cached/uuid | grep -iE 'x-cache-status'
curl -si -H 'Authorization: Bearer bob'   http://localhost:8080/cached/uuid | grep -iE 'x-cache-status'
```

Bob gets a `HIT`. Different credentials, same cached bytes.

Two defenses. Either don't cache authenticated traffic:

```nginx
proxy_no_cache     $http_authorization;
proxy_cache_bypass $http_authorization;
```

or make identity part of the key, which only works if you're certain the
identity is fully captured:

```nginx
proxy_cache_key "$scheme$request_method$host$request_uri$http_authorization";
```

The first is almost always the right choice. Add the `proxy_no_cache` lines and
confirm Bob stops getting Alice's response.

## Step 4 — who decides what's cacheable?

By default nginx respects the backend's `Cache-Control`. go-httpbin lets you
control it:

```bash
curl -si http://localhost:8080/cached/cache/60      | grep -iE 'cache-control|x-cache-status'
curl -si http://localhost:8080/cached/cache/60      | grep -i x-cache-status
curl -si http://localhost:8080/cached/response-headers?Cache-Control=no-store \
                                                     | grep -i x-cache-status
```

`no-store` is never cached, regardless of `proxy_cache_valid`. Your
`proxy_cache_valid 200 30s;` is a *fallback* for responses that don't say. To
override the backend deliberately, `proxy_ignore_headers Cache-Control;` — a
sharp tool, since you're now overruling the team that owns the data.

## Step 5 — conditional requests

`ETag` and `If-None-Match` are a different mechanism, often confused with
caching:

```bash
ETAG=$(curl -si http://localhost:8080/cached/etag/abc123 | grep -i '^etag' | tr -d '\r' | cut -d' ' -f2)
echo "etag: $ETAG"
curl -si -H "If-None-Match: $ETAG" http://localhost:8080/cached/etag/abc123 | head -1
```

`304 Not Modified`, with no body. Caching avoids the *backend call*; conditional
requests avoid the *body transfer* when the client already has a valid copy.
They compose — a gateway can hold the cache and answer 304s from it.

## Step 6 — cache stampede

The failure mode that catches teams the moment they get real traffic. When a
popular key expires, every concurrent request misses simultaneously and they all
stampede the backend at once.

```bash
bin/chaos.sh latency 2000
bin/loadtest.sh /cached/delay/1 20 20
bin/chaos.sh reset
```

Watch the log: 20 requests, 20 upstream calls, for one key. Now uncomment:

```nginx
proxy_cache_lock on;
```

```bash
docker compose restart gateway
bin/chaos.sh latency 2000
bin/loadtest.sh /cached/delay/1 20 20
bin/chaos.sh reset
```

One upstream call. The rest waited for it and shared the result. On a hot key
this is the difference between one backend request and ten thousand.

## Step 7 — stale content beats an error page

The highest-value cache setting, and the least used. Uncomment:

```nginx
proxy_cache_use_stale error timeout updating http_500 http_502 http_503;
proxy_cache_background_update on;
```

```bash
docker compose restart gateway
curl -s http://localhost:8080/cached/uuid > /dev/null   # warm it
bin/chaos.sh down                                        # backend offline
curl -si http://localhost:8080/cached/uuid | grep -iE 'x-cache-status|^HTTP'
bin/chaos.sh up
```

`200`, status `STALE`. The backend is completely offline and users are still
being served.

Slightly-old data is nearly always better than a 503. `updating` in that list
means: while one request refreshes the entry, everyone else keeps getting the
stale copy rather than queueing. Combined with
`proxy_cache_background_update on`, users effectively never wait for a refresh.

## Step 8 — the hard part

None of the above tells you how to *invalidate*. Open-source nginx has no purge
API (`proxy_cache_purge` is nginx Plus), so your options are TTLs short enough
that staleness is tolerable, or a versioned cache key you can bump —
`/v2/balanced/...` — which invalidates by making the old key unreachable rather
than by deleting anything.

The general lesson: cache invalidation is a data-modelling problem, not a
gateway feature. Deciding what may be stale, and for how long, is a product
decision that no config file can make for you.

## What you learned

- The cache key is an authorization boundary; omitting identity leaks data.
- `proxy_cache_valid` is a fallback — the backend's `Cache-Control` wins.
- Caching and conditional requests solve different problems and compose.
- `proxy_cache_lock` collapses stampedes on hot keys.
- `proxy_cache_use_stale` keeps you up when the backend is down.
- Invalidation is the genuinely hard part and nginx barely helps.

---

Prev: [04 — timeouts and retries](04-timeouts-and-retries.md) · Next: [06 — rate limiting](06-rate-limiting.md)
