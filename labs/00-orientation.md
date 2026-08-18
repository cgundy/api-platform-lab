# Lab 00 — Orientation

Before changing anything, get familiar with the pieces. ~10 minutes.

## The shape of the thing

```
  you (curl)
      |
      v
  gateway (nginx)  :8080
      |
      +--> users_pool  --> users1 :9001 , users2 :9002    echo servers
      +--> orders_pool --> toxiproxy --> orders :9003     go-httpbin
      +--> flaky_pool  --> flaky1 :9004 , flaky2 :9005    go-httpbin
```

The gateway is the only thing you edit. The backends are stock images and never
change — everything you learn is about the layer in front of them.

Every backend is *also* published directly on your host (ports 9001–9005). That
is the most useful property of this lab: you can always ask "what does the
request look like when it skips the gateway?" and diff the two.

## Two windows

Open a second terminal and leave the gateway's log running in it:

```bash
docker compose logs -f gateway
```

Almost every lab is "run a curl in window 1, read the log line it produced in
window 2". The log format is defined at the top of `nginx/nginx.conf`:

```
172.18.0.1 "GET /users/ HTTP/1.1" -> 200 upstream=172.18.0.4:8080 ustatus=200 rt=0.004 urt=0.004 cache=- rid=abc123
```

| Field | Means |
|---|---|
| `-> 200` | what the **client** got |
| `upstream=` | which backend actually served it |
| `ustatus=` | what the **backend** said (differs from `->` when retries or cache are involved) |
| `rt=` | total time the client waited |
| `urt=` | time the backend took — so `rt - urt` is time nginx spent |
| `cache=` | `HIT`, `MISS`, `BYPASS`, `EXPIRED`, `STALE`, or `-` when caching is off |

## Meet the backends

The echo server tells you exactly what it received:

```bash
curl -s http://localhost:9001/hello | python3 -m json.tool
```

Note `path`, `headers`, and `os.hostname`. That `hostname` is how you'll tell
`users1` from `users2` later.

go-httpbin has behaviors built in, which is why this lab needs no code:

```bash
curl -s  http://localhost:9003/get                        # plain 200 + JSON
curl -si http://localhost:9003/status/503 | head -1       # any status you want
curl -s  -o /dev/null -w '%{time_total}s\n' \
         http://localhost:9003/delay/2                    # a slow endpoint
curl -si http://localhost:9003/cache/60 | grep -i cache   # cacheable response
curl -si 'http://localhost:9003/status/200:0.5,500:0.5' | head -1   # random!
```

That last one is the important trick. The weighted form
`status/200:0.5,500:0.5` returns 200 half the time and 500 the other half — run
it five times and you'll get a different answer. That randomness is what makes
retries and circuit breakers observable in labs 4 and 8.

## Meet the gateway

```bash
curl -s http://localhost:8080/
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/users/anything | python3 -m json.tool
```

Watch the log window while you run the last one a few times. The `upstream=`
address changes between two IPs — you are already load balancing and haven't
configured anything.

## The edit loop

Every lab is the same three steps:

1. Run a `curl` and note what happens.
2. Uncomment a few lines in `nginx/nginx.conf` (they're all tagged with the lab
   number, e.g. `# LAB 4 step 3:`).
3. `docker compose restart gateway`, then run the same `curl` again.

Before restarting, it's worth checking your edit parses:

```bash
docker compose exec gateway nginx -t
```

If you typo something, `restart` will leave the gateway dead and every request
will hang or refuse. `nginx -t` catches it in a second.

There's also a faster reload that doesn't drop connections:

```bash
docker compose exec gateway nginx -s reload
```

That's what you'd actually use in production — the old workers finish their
in-flight requests while new ones start with the new config. `restart` is
blunter but always works, so the labs use it.

---

Next: [01 — what a proxy actually does](01-what-a-proxy-does.md)
