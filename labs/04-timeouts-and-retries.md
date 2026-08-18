# Lab 04 — Timeouts and retries

The two settings most likely to turn a small backend problem into a total
outage. Both defaults are wrong for an API.

## Step 1 — the default timeout is 60 seconds

```bash
bin/chaos.sh latency 5000
time curl -s -o /dev/null http://localhost:8080/network-chaos/get
bin/chaos.sh reset
```

Five seconds, and nginx waited patiently. Its default `proxy_read_timeout` is
**60s**. Ask what that means at scale: if a backend hangs, every request to it
occupies a gateway worker slot for a full minute. Traffic arriving at 100 req/s
means 6,000 requests piled up in the gateway before the first one gives up. The
gateway — the component whose job is to protect you — becomes the thing that
falls over.

## Step 2 — make it hang completely

```bash
bin/chaos.sh timeout
time curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/network-chaos/get
```

60 seconds, then `504 Gateway Timeout`. Ctrl-C if you don't want to wait.

Note the failure *mode* here. `bin/chaos.sh down` (connection refused) fails in
milliseconds — the kernel answers immediately. A hang gives you nothing to react
to. This is why "the backend is down" is often easier to survive than "the
backend is slow", and why timeouts exist.

## Step 3 — set real timeouts

Uncomment in the `/network-chaos/` block:

```nginx
proxy_connect_timeout 2s;
proxy_send_timeout    2s;
proxy_read_timeout    2s;
```

```bash
docker compose exec gateway nginx -t
docker compose restart gateway
time curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/network-chaos/get
bin/chaos.sh reset
```

504 in 2 seconds instead of 60.

The three are different things and people conflate them:

- `proxy_connect_timeout` — TCP handshake only. Should be *short* (1–2s); on a
  healthy network a connection either establishes fast or isn't going to.
- `proxy_send_timeout` — gap while writing the request to the backend.
- `proxy_read_timeout` — gap between successive reads of the response. **Not** a
  total-time budget. A backend that dribbles one byte every second forever will
  never trip it. That's the "slowloris" pattern, in reverse.

Pick the read timeout from your endpoint's real p99, plus headroom — not from a
round number. And set it per-location: a report endpoint that legitimately takes
20 seconds shouldn't force a 20-second timeout on your entire API.

## Step 4 — see the flaky backend

```bash
bin/loadtest.sh '/flaky/status/200:0.5,500:0.5' 40 1
```

Roughly half 200s, half 500s. Two backends, both failing independently at 50%.

## Step 5 — turn on retries

Uncomment in the `/flaky/` block:

```nginx
proxy_next_upstream         error timeout http_500 http_502 http_503;
proxy_next_upstream_tries   3;
proxy_next_upstream_timeout 5s;
```

```bash
docker compose restart gateway
bin/loadtest.sh '/flaky/status/200:0.5,500:0.5' 40 1
```

The 500s largely disappear. With a 50% failure rate and up to 3 attempts, the
chance a request fails all three is 0.5³ ≈ 12%.

Now read the gateway log:

```
"GET /flaky/... " -> 200 upstream=172.18.0.6:8080, 172.18.0.7:8080 ustatus=500, 200
```

Two addresses in `upstream=`, two codes in `ustatus=`. The client got a 200; the
backends served a 500 and then a 200. **Your error rate as measured at the
gateway is now a lie about backend health.** If you alert on gateway 5xx, you
have just made yourself blind to a backend that's failing half the time. Alert
on `ustatus` too.

## Step 6 — the dangerous part

Note what is *not* in that `proxy_next_upstream` list: `non_idempotent`.

By default nginx retries `GET`, `HEAD`, `PUT`, `DELETE` and friends, but
**refuses to retry `POST`** — unless you add `non_idempotent`, which you should
think very hard about. A `POST /payments` that times out may have succeeded;
the backend charged the card and the response got lost. Retrying charges twice.

The correct fix isn't at the gateway — it's idempotency keys, where the client
sends a unique key per logical operation and the backend deduplicates. Stripe's
API is the canonical example. The gateway can only decide *whether* to retry; it
can't make a retry safe.

## Step 7 — retries as an outage amplifier

This is the one that takes down real systems.

```bash
docker compose stop random-status-code-2
bin/loadtest.sh '/flaky/status/200:0.5,500:0.5' 60 10
docker compose start random-status-code-2
```

With one backend gone, every failure retries onto the survivor. You removed 50%
of capacity and *increased* the load on what's left — up to 3× per request. A
backend that's struggling gets hit with a traffic multiplier at exactly the
moment it can least afford one. That is a retry storm, and it's how a partial
degradation becomes a full outage.

Three mitigations, none of which nginx open source gives you:

1. **Exponential backoff with jitter** — wait longer between attempts, randomly,
   so clients don't synchronize into waves.
2. **Retry budgets** — cap retries at e.g. 10% of total requests, so retries can
   never more than 1.1× your load. Envoy has this natively.
3. **Circuit breakers** — after N consecutive failures, stop calling the backend
   entirely for a cooldown, failing fast instead. `max_fails` / `fail_timeout`
   from lab 3 is a crude version; Envoy's outlier detection is the real one.

nginx has no backoff and no budget: its retries are immediate and unbounded per
request. Setting `proxy_next_upstream_tries` low (2, occasionally 3) is the main
lever you have. "Retry harder" is the intuitive response to failures and it is
frequently the wrong one.

## What you learned

- Default 60s timeouts turn a slow backend into a gateway outage.
- Connect / send / read timeouts are different; read timeout is per-read, not
  total.
- A hung backend is worse than a refused one.
- Retries hide backend failure from your metrics.
- Retrying non-idempotent requests can double-charge people.
- Retries multiply load precisely when capacity has dropped.

---

Prev: [03 — load balancing](03-load-balancing.md) · Next: [05 — caching](05-caching.md)
