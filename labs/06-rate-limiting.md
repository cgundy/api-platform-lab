# Lab 06 — Rate limiting

Rate limiting is where "gateway" starts becoming "API management". The mechanics
are simple; choosing the key is the part that decides whether it protects you or
just annoys people.

## Step 1 — unlimited

```bash
bin/loadtest.sh /limited/ 50 10
```

50 × 200. Nothing is stopping anyone.

## Step 2 — turn on a limit

The zone is already declared at the top of `nginx.conf`:

```nginx
limit_req_zone $binary_remote_addr zone=perip:10m rate=5r/s;
```

Uncomment in `/limited/`:

```nginx
limit_req        zone=perip burst=5 nodelay;
limit_req_status 429;
```

```bash
docker compose exec gateway nginx -t
docker compose restart gateway
bin/loadtest.sh /limited/ 50 10
```

Now a handful of 200s and a pile of 429s.

`$binary_remote_addr` rather than `$remote_addr` is deliberate: it stores the IP
as 4 bytes instead of a string, so a 10MB zone holds ~160,000 addresses. At
gateway scale that difference is real.

Note also that `limit_req_status 429` is opt-in — nginx's default is **503**,
which is wrong. 503 says "I'm broken, try later"; 429 says "you're over quota".
Clients and monitoring treat those very differently.

## Step 3 — burst, and what nodelay does

Three configurations, materially different behavior:

```nginx
limit_req zone=perip;                      # strict: >5r/s is rejected, period
limit_req zone=perip burst=5;              # queue up to 5, release at 5r/s
limit_req zone=perip burst=5 nodelay;      # serve 5 instantly, then reject
```

Try the middle one — remove `nodelay`, restart, and:

```bash
bin/loadtest.sh /limited/ 20 20
```

Almost no 429s, but look at the latency numbers. Requests aren't rejected,
they're **held** and released at 5/s. That's a leaky bucket: it smooths traffic
instead of refusing it.

Which you want depends on the client. A batch job would rather wait than fail.
An interactive API should reject fast — a queued request that eventually
succeeds after 8 seconds is worse than an immediate 429 the client can back off
from. Delay also ties up gateway workers, so a delayed limit under real abuse
can exhaust the thing you were protecting.

Put `nodelay` back.

## Step 4 — tell the client what happened

A bare 429 is hostile. Well-behaved APIs say when to come back:

```nginx
limit_req_status 429;
add_header Retry-After 1 always;
```

The `always` matters — without it, `add_header` only applies to 2xx/3xx
responses, so it would be absent from exactly the 429s that need it.

There's a real limitation here: open-source nginx cannot emit
`X-RateLimit-Remaining` — it has no variable exposing the current bucket level.
Proper quota headers are one of the clearest reasons to move to Kong, Envoy or
Apigee. It's a good example of a gateway feature that looks trivial and isn't.

## Step 5 — the key is the whole design

`$binary_remote_addr` looks obvious and is usually wrong:

- Every user behind one corporate NAT or mobile carrier shares a bucket. One
  heavy user rate-limits an entire office.
- IPv6 clients get a fresh /64 practically for free, so a determined abuser just
  rotates addresses.
- **If your gateway is behind a CDN or load balancer, `$remote_addr` is that
  proxy's address** — so you've built one global bucket for all traffic. The
  first burst locks out the entire internet. This is a genuinely common
  production incident.

That last one is lab 1's `X-Forwarded-For` lesson arriving with consequences.
Behind a trusted proxy you need nginx's realip module to rewrite `$remote_addr`
before the limit is evaluated:

```nginx
set_real_ip_from 10.0.0.0/8;      # only your own proxies
real_ip_header   X-Forwarded-For;
real_ip_recursive on;
```

And note the ordering trap: if you skip `set_real_ip_from` and key on
`$http_x_forwarded_for` directly, any client can send a random value per request
and get unlimited quota.

## Step 6 — rate limit by identity instead

The zone keyed on an API key is already declared:

```nginx
limit_req_zone $http_x_api_key zone=perkey:10m rate=2r/s;
```

Uncomment in `/limited-by-key/`:

```nginx
limit_req        zone=perkey burst=2 nodelay;
limit_req_status 429;
```

```bash
docker compose restart gateway

for i in $(seq 1 10); do
  curl -s -o /dev/null -w '%{http_code} ' -H 'X-Api-Key: alice' http://localhost:8080/limited-by-key/
done; echo

for i in $(seq 1 10); do
  curl -s -o /dev/null -w '%{http_code} ' -H 'X-Api-Key: bob' http://localhost:8080/limited-by-key/
done; echo
```

Alice and Bob have independent buckets. This is what "10,000 requests/month on
the free tier" is actually made of.

## Step 7 — the bug hiding in that config

Now call it with no key at all:

```bash
for i in $(seq 1 20); do
  curl -s -o /dev/null -w '%{http_code} ' http://localhost:8080/limited-by-key/
done; echo
```

Twenty 200s. **No limit applied at all.**

When the key variable evaluates to an empty string, nginx skips the limit
entirely. So a config that limits authenticated users places *no* limit on
anonymous ones — precisely backwards, and it looks completely fine in review.

The fix is to require the key before limiting on it:

```nginx
if ($http_x_api_key = "") { return 401; }
```

Better: combine the keys with `map`, so a missing API key falls back to IP:

```nginx
map $http_x_api_key $limit_key {
    default  $http_x_api_key;
    ""       $binary_remote_addr;
}
limit_req_zone $limit_key zone=combined:10m rate=5r/s;
```

## Step 8 — concurrency is a different limit

Rate caps requests per second. It does nothing about ten requests that each run
for a minute. Uncomment in `/concurrent/`:

```nginx
limit_conn        perip_conn 2;
limit_conn_status 429;
```

```bash
docker compose restart gateway
bin/loadtest.sh /concurrent/delay/2 10 10
```

Two succeed, the rest get 429 — regardless of rate. Concurrency limits are what
protect a backend with a fixed worker or connection pool, and they're the more
important of the two for expensive endpoints.

## Step 9 — the limit is per gateway instance

Everything here lives in that gateway's local shared memory. Run three nginx
instances behind a load balancer with `rate=5r/s` and your real limit is 15r/s —
and it drifts as instances scale.

Distributed rate limiting needs shared state (Redis, or a dedicated rate-limit
service) and brings its own problems: a network round trip in the hot path, and
a decision about what to do when the store is unreachable. Fail open and you've
removed your protection during an incident; fail closed and you've turned a
Redis blip into a full outage. Kong and Envoy both ship this; nginx does not.

## What you learned

- `limit_req_status 429` is opt-in; the 503 default misinforms clients.
- `burst` without `nodelay` delays, with `nodelay` rejects — pick per client type.
- Keying on IP breaks behind NAT and catastrophically behind a proxy.
- An empty key variable disables the limit silently.
- Rate and concurrency limits protect against different failures.
- Local counters don't survive horizontal scaling.

---

Prev: [05 — caching](05-caching.md) · Next: [07 — TLS termination](07-tls-termination.md)
