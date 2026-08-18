# Lab 08 — Network chaos

Everything so far assumed the network either works or refuses. Real networks
fail in more interesting ways, and those are the ones that take systems down.
Toxiproxy sits between the gateway and `orders`, so you can damage the wire
itself at runtime.

```bash
bin/chaos.sh status
```

Only `/orders/` and `/cached/` route through it. `/users/` and `/flaky/` are
unaffected, which is useful — you always have a control group.

## Step 1 — the four ways a backend fails

| Failure | Command | How it feels |
|---|---|---|
| refused | `bin/chaos.sh down` | instant error |
| slow | `bin/chaos.sh latency 3000` | everything still works, just worse |
| throttled | `bin/chaos.sh slow 512` | small responses fine, large ones crawl |
| hung | `bin/chaos.sh timeout` | nothing comes back, ever |

Time each one:

```bash
for mode in down latency timeout; do
  bin/chaos.sh $mode > /dev/null
  printf '%-8s ' "$mode"
  curl -s -o /dev/null -w 'code=%{http_code} time=%{time_total}s\n' \
    --max-time 10 http://localhost:8080/orders/get
done
bin/chaos.sh reset
```

The ranking is counterintuitive: `down` is the **easiest** failure to survive.
The kernel refuses instantly, nginx marks the backend bad and moves on, users
get a fast error. `timeout` is the worst — no signal at all, and every request
occupies a gateway worker until it gives up.

This is why "is it up?" is the wrong health question. Systems rarely fail by
stopping; they fail by getting slow.

## Step 2 — latency is not a constant

```bash
bin/chaos.sh latency 200
bin/loadtest.sh /orders/get 30 5
bin/chaos.sh reset
```

Compare mean against p95. `bin/chaos.sh` adds 100ms of jitter, so the tail is
noticeably worse than the average — and that's with one hop and no queueing.

Averages hide everything that matters. If your API makes 10 backend calls and
each has a p99 of 1s, the chance that *none* of them hits the slow path is
0.99¹⁰ ≈ 90% — so roughly one in ten user requests hits a p99 somewhere. Tail
latency compounds with fan-out, which is why "our average is 40ms" tells you
almost nothing about what users experience.

## Step 3 — bandwidth

```bash
bin/chaos.sh slow 2048
curl -s -o /dev/null -w 'small: %{time_total}s\n' http://localhost:8080/orders/bytes/1024
curl -s -o /dev/null -w 'large: %{time_total}s\n' http://localhost:8080/orders/bytes/102400
bin/chaos.sh reset
```

Small responses are fine, large ones crawl. Remember from lab 4 that
`proxy_read_timeout` is the gap *between reads*, not total time — a slow
transfer streaming steadily will never trip it while tying up a worker for
minutes. If total time matters, you need something else (a response size limit,
or `proxy_max_temp_file_size` behavior, or a real total-time budget at a layer
that has one).

## Step 4 — combine chaos with your defenses

This is where the whole lab comes together. Make the backend completely dead:

```bash
bin/chaos.sh timeout
```

Now compare three routes:

```bash
curl -s -o /dev/null -w 'plain:  %{http_code} in %{time_total}s\n' --max-time 70 http://localhost:8080/orders/get
curl -s -o /dev/null -w 'cached: %{http_code} in %{time_total}s\n' --max-time 70 http://localhost:8080/cached/uuid
bin/chaos.sh reset
```

If you did labs 4 and 5, `/orders/` fails fast with a 504 (timeouts) and
`/cached/` serves a `STALE` 200 (`proxy_cache_use_stale`). One route is down,
the other is still serving users, and the difference is four lines of config.

Warm the cache first if `/cached/` gives you a 504 — stale only works if
something was stored:

```bash
curl -s http://localhost:8080/cached/uuid > /dev/null
```

## Step 5 — what you can't see from here

Run this and watch the gateway log:

```bash
bin/chaos.sh latency 2000
curl -s -o /dev/null http://localhost:8080/orders/get
bin/chaos.sh reset
```

You get `rt=2.0 urt=2.0`. The gateway says the backend took 2 seconds. The
backend's own logs will say it responded in 3ms — because the delay was on the
wire, not in the application.

This gap is exactly why distributed tracing exists. Two logs, both honest, that
disagree about what happened. `X-Request-ID` (set back in lab 1) is the seed of
the fix: propagate one ID through every hop and you can line the story up.
W3C Trace Context (`traceparent`) is the standardized version, and OpenTelemetry
is the usual implementation.

## Step 6 — what a real gateway adds

You've now hit several walls that are properties of nginx specifically, not of
gateways in general:

| You wanted | nginx OSS | Envoy / Kong |
|---|---|---|
| active health checks | no | yes |
| circuit breaking | `max_fails` only | outlier detection |
| retry backoff + budgets | no | yes |
| `X-RateLimit-*` headers | no | yes |
| distributed rate limits | no | yes |
| JWT validation | no | built in |
| per-route metrics | no | Prometheus endpoint |
| config without restart | reload | dynamic (xDS / admin API) |

That table is the honest argument for the next phase. nginx taught you the
mechanics — proxying, routing, balancing, caching, TLS — and those concepts
transfer unchanged. What it can't teach you is the API management layer:
consumers, credentials, quotas per plan, and turning policy on per route without
editing a file.

## Step 7 — clean up

```bash
bin/chaos.sh reset
bin/chaos.sh status
```

## What you learned

- A refused connection is the *friendliest* failure; a hang is the worst.
- Tail latency, not average, is what users experience — and it compounds with
  fan-out.
- Read timeouts don't bound total transfer time.
- Caching plus timeouts keeps you serving through a total backend outage.
- Gateway and backend logs can both be right and still disagree — that's what
  tracing is for.

---

Prev: [07 — TLS termination](07-tls-termination.md) · Back to [README](../README.md)
