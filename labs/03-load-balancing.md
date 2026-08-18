# Lab 03 — Load balancing

You already have two `users` instances behind one pool. This lab is about
watching the distribution change, and about what happens when one instance dies.

Keep `docker compose logs -f gateway` open for all of it — `upstream=` is the
whole story.

## Step 1 — see round-robin

```bash
for i in $(seq 1 6); do
  curl -s http://localhost:8080/users/hostname \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["os"]["hostname"])'
done
```

Strict alternation: `users1`, `users2`, `users1`, `users2`… That's nginx's
default and it needs no configuration at all — listing two `server` lines in an
`upstream` block was enough.

## Step 1b — why that only works because of one line

The pool starts with `zone users_pool 64k;`. Delete that line and restart:

```bash
docker compose restart gateway
for i in $(seq 1 8); do
  curl -s http://localhost:8080/users/hostname \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["os"]["hostname"])'
done
```

Every request now hits `users1`. But run concurrent load and check the log:

```bash
bin/loadtest.sh /users/ 60 8 > /dev/null
docker compose logs gateway | grep '"GET /users/ ' | tail -60 \
  | sed 's/.*upstream=\([^ ]*\).*/\1/' | sort | uniq -c
```

A clean 30/30 split. So it *is* balancing — just not the way you expected.

`worker_processes auto` starts one nginx worker per core (10 on an M1 Pro).
Without a shared memory `zone`, **each worker keeps its own round-robin counter
and its own health state** — you have 10 independent load balancers that never
compare notes. Sequential `curl`s each land on a different idle worker, and
every one of them starts counting at the first backend. Under concurrent load
the workers are all busy and the aggregate averages out.

This matters well beyond a confusing demo: without `zone`, `max_fails` is also
per-worker, so a dead backend has to fail 10 separate times before every worker
agrees it's dead. Put the `zone` line back before continuing.

Round-robin is stateless and fair *if* every request costs the same. It has no
idea that request #3 is a 4-second report and request #4 is a 2ms health check.

## Step 2 — weights

Change `users_pool` in `nginx.conf`:

```nginx
upstream users_pool {
    server users1:8080 weight=3;
    server users2:8080;
}
```

```bash
docker compose restart gateway
bin/loadtest.sh /users/hostname 40 1
```

Then count how it actually split:

```bash
for i in $(seq 1 40); do
  curl -s http://localhost:8080/users/hostname \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["os"]["hostname"])'
done | sort | uniq -c
```

Roughly 3:1. Weights are how you shift traffic gradually — a canary release is
just a pool where the new version starts at `weight=1` against `weight=99` and
climbs.

## Step 3 — least_conn

Uncomment `least_conn;` in the pool (and remove the weight). Round-robin's
weakness shows up when request costs vary wildly:

```bash
# terminal 1 - tie up one backend with slow requests
for i in $(seq 1 5); do curl -s http://localhost:9003/delay/5 >/dev/null & done

# terminal 2 - normal traffic
bin/loadtest.sh /users/ 20 4
```

`least_conn` sends each new request to whichever backend has the fewest requests
in flight, so a backend stuck on slow work stops receiving new ones. For APIs
with mixed endpoint costs this is usually a better default than round-robin.

## Step 4 — session affinity (and why to avoid it)

Uncomment `ip_hash;` instead:

```bash
docker compose restart gateway
for i in $(seq 1 6); do
  curl -s http://localhost:8080/users/hostname \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["os"]["hostname"])'
done
```

All six hit the same backend. nginx hashes your client IP and picks
deterministically — "sticky sessions", which exist so a backend holding
in-memory session state keeps seeing the same user.

It also means your load is only as even as your client IP distribution, that a
single NAT'd office lands entirely on one instance, and that removing a backend
reshuffles everyone. The modern answer is to make backends stateless and keep
session state in Redis or a signed cookie, so you never need affinity. Know how
it works; treat needing it as a smell.

Comment `ip_hash` back out before continuing.

## Step 5 — kill a backend

With the pool back to plain round-robin:

```bash
docker compose stop users2
bin/loadtest.sh /users/ 20 1
```

You'll see a few 502s at first, then clean 200s. nginx noticed the connection
was refused, marked `users2` failed, and stopped sending to it.

That's a **passive health check** — nginx learns a backend is down by *failing a
real user's request against it*. Some of your users paid for that discovery.
Make the behavior explicit:

```nginx
server users1:8080;
server users2:8080 max_fails=2 fail_timeout=10s;
```

Two failures inside 10s ejects the backend for 10s, then it's tried again.
Tuning is a real tradeoff: `max_fails=1` ejects fast but flaps on a single blip;
`max_fails=10` is stable but leaks a lot of errors to users first.

Bring it back and watch traffic return:

```bash
docker compose start users2
```

One trap while `users2` is stopped: **don't restart the gateway.** nginx
resolves upstream hostnames once at startup and refuses to boot if one doesn't
resolve — you'd get `host not found in upstream "users2"` and a dead gateway.
Start the backend first. Production configs work around this with a `resolver`
directive and a variable in `proxy_pass`, which defers the lookup to request
time.

## Step 6 — what open-source nginx can't do

**Active** health checks — the gateway polling `/healthz` on a schedule and
ejecting backends *before* a user hits them — are an nginx Plus feature. Open
source nginx only has the passive kind you just used.

This is a genuine reason teams move to Envoy, HAProxy or Traefik, all of which
do active checks for free. It's worth knowing which limitations belong to
"reverse proxies" and which belong to "this particular reverse proxy".

## Step 7 — connection reuse

Uncomment `keepalive 32;` in the pool. Without it, nginx opens a fresh TCP
connection to a backend for every single request — a handshake per request, and
a steady supply of sockets in `TIME_WAIT`.

`keepalive` keeps a pool of idle connections warm. It requires
`proxy_http_version 1.1` and an empty `Connection` header, which is why
`proxy-headers.conf` sets the version. Measure it:

```bash
bin/loadtest.sh /users/ 200 10
```

On a local network the win is small. Across a real network, where a handshake
costs a round trip (and a TLS handshake costs two), it's one of the largest
easy wins available at the gateway.

## What you learned

- Round-robin is free but assumes uniform request cost; `least_conn` doesn't.
- Weights are the mechanism behind canary and gradual rollouts.
- Sticky sessions solve a problem you should design away instead.
- Passive health checks discover failures using real user requests. Active
  checks are what you actually want, and open-source nginx lacks them.
- Upstream keepalive matters more the further away your backends are.

---

Prev: [02 — routing](02-routing.md) · Next: [04 — timeouts and retries](04-timeouts-and-retries.md)
