# API Platform Lab

A local API gateway you can break on purpose.

Seven containers, **zero application code**: nginx out front, five stock backend
images behind it, and Toxiproxy on the wire so you can damage the network at
runtime. You learn by editing one config file, restarting, and watching what
changes.

Covers HTTP proxying, routing, load balancing, timeouts and retries, caching,
rate limiting, TLS termination, and network failure modes.

---

## Concepts: proxies, gateways, and security

**Proxy** is the general term: something that sits between a client and a
server and forwards traffic on someone's behalf.

- A **forward proxy** sits in front of the *client* — it hides who's asking.
  Corporate web filters and VPN exit nodes are forward proxies.
- A **reverse proxy** sits in front of the *server* — it hides how many
  backends there are, what they're built with, and where they live. This is
  the kind of proxy this lab is about. When you `curl localhost:8080`, you're
  talking to nginx; nginx decides which backend actually handles it.

**Gateway** (specifically "API gateway") is a reverse proxy with policy
bolted on. A plain reverse proxy forwards bytes; a gateway also makes
decisions: which route does this path belong to, which backend is healthy,
has this client exceeded its quota, is this request even allowed in. Kong,
Envoy, and Amazon API Gateway are all API gateways — nginx *can* act as one
(that's what `nginx.conf` in this lab is building up, route by route), but
open-source nginx stops short of things like JWT validation or per-consumer
quotas without extra modules. That gap is called out at the bottom of this
README.

**Why this sits on the security boundary.** The reverse proxy is usually the
first thing an external request touches, which makes it the natural place to
enforce boundaries rather than trust each backend to enforce them
individually:

- **TLS termination** — the proxy holds the certificate and decrypts traffic,
  so backends never see raw key material (lab 07).
- **Header trust** — every request arriving at a backend carries headers the
  proxy chose to forward or overwrite. Get this wrong and a client can spoof
  `X-Forwarded-For` or hop-by-hop headers meant to be proxy-only (lab 01).
- **Rate limiting** — throttling lives at the edge so one bad actor (or bug)
  can't take down a shared backend (lab 06).
- **Failure isolation** — timeouts, retries, and caching decide whether one
  slow or dead backend cascades into an outage for everyone behind the
  gateway (labs 04, 05, 08).

None of this is abstract in the lab — each bullet above is a config change
you make yourself and then watch break or fix a `curl` response.

## What's built here

Seven containers, zero application code:

- **`gateway`** — `nginx`, the one thing you edit. Terminates TLS, routes by
  path, load-balances, rate-limits, and caches, depending on which lab you're
  in.
- **Five stock backend images** (`echo1`/`echo2`, `random-status-code-with-caching`,
  `random-status-code-1`/`random-status-code-2`) — off-the-shelf test servers,
  not code written for this lab. Both container names and route names
  (`/balanced/`, `/network-chaos/`, `/flaky/`, `/cached/`, ...) describe what
  they demonstrate, at two different layers: the route is *what a lab is
  teaching* (load balancing, network chaos), the container is *what's
  actually behind it* (an echo server, a random-status generator).
  `echo1`/`echo2` just echo your request back as JSON.
  `random-status-code-with-caching` and the `random-status-code-1`/`-2` pair
  all run the *same* image (`go-httpbin`) and are equally capable of both
  tricks — they're only split up because the labs use them for different
  things: the former for delay/cache/etag and network chaos, the pair for
  demonstrating retries against random failures.
- **`toxiproxy`** — sits on the wire between the gateway and
  `random-status-code-with-caching` and lets
  you inject latency, bandwidth throttling, or a dead connection at runtime,
  without restarting anything, so you can watch how the gateway's timeout and
  retry settings actually behave under failure (lab 08).

Everything is orchestrated by [`docker-compose.yml`](docker-compose.yml), and
every container is hardened the same way — pinned image digests, dropped
Linux capabilities, `no-new-privileges`, memory limits, loopback-only ports —
detailed in [Security posture of the lab itself](#security-posture-of-the-lab-itself)
below.

---

## Getting started

### 1. Install Docker

Not currently installed on this machine. On macOS:

```bash
brew install --cask docker
```

Then launch Docker from your Applications folder and wait for the whale icon in
the menu bar to stop animating. Verify:

```bash
docker compose version
```

<details>
<summary>Alternatives (colima, OrbStack)</summary>

Docker on macOS always needs a Linux VM. Any of these provide one — the lab
doesn't care which:

- `brew install colima docker docker-compose && colima start` — CLI only, no
  password prompt, nothing to click.
- `brew install --cask orbstack` — fastest on Apple Silicon, has a GUI. Paid for
  commercial use at larger companies.

</details>

### 2. Start the stack

```bash
cd api-platform-lab
docker compose up -d
```

First run pulls ~5 images and takes a couple of minutes. Then:

```bash
docker compose ps
```

All seven should say `running`, and `lab-gateway` should reach `healthy` within
about 15 seconds.

### 3. Check it works

```bash
curl http://localhost:8080/healthz
curl -s http://localhost:8080/balanced/hello | python3 -m json.tool
```

The second one returns a JSON echo of your own request as the backend received
it. Run it a few times and watch the `os.hostname` field alternate between
`echo1` and `echo2` — you're already load balancing.

### 4. Make the scripts executable

```bash
chmod +x bin/*.sh
```

### 5. Open a log window

Keep this running in a second terminal for every lab:

```bash
docker compose logs -f gateway
```

### 6. Start the labs

```bash
open labs/00-orientation.md
```

Work through them in order — each builds on the last. Roughly 15 minutes each.

---

## Working with the containers

All commands below assume you're in the `api-platform-lab` directory, since
`docker compose` reads `docker-compose.yml` from the current directory (or
finds it by the `name: api-platform-lab` set at the top of the file).

There's also a [`Makefile`](Makefile) with a short target for most of these —
run `make help` to list them (`make up`, `make ps`, `make logs`,
`make logs SERVICE=random-status-code-with-caching`, `make check`, `make restart`, `make reload`,
`make reset`, ...). `make <TAB>` tab-completes target names in bash and zsh
without any extra setup, so it's the fastest way to drive the lab without
typing `docker compose` every time.

### Starting and stopping

```bash
docker compose up -d              # start everything, detached
docker compose up -d gateway      # start (or restart) just one service
docker compose stop               # stop containers, keep them (fast to resume)
docker compose down               # stop and remove containers + network
docker compose down -v            # also remove volumes — full reset
```

### Seeing what's up

```bash
docker compose ps                 # this project's containers + health + ports
docker compose ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'
docker ps                         # every container on the machine, not just this project
```

`docker compose ps` is the one to reach for first — it's scoped to this
project, and shows each service's state (`running`, `exited`, `restarting`)
next to its health check result. `lab-gateway` has an actual health check
(`healthy`/`unhealthy`/`starting`); the backends don't define one, so they
just show `running`. To inspect a health check's own history:

```bash
docker inspect lab-gateway --format '{{json .State.Health}}' | python3 -m json.tool
```

### Logs

```bash
docker compose logs -f gateway         # follow one service (leave this open in a second terminal)
docker compose logs -f                 # follow everything, interleaved
docker compose logs --tail 50 echo1    # last 50 lines, no follow
```

### Getting inside a container

```bash
docker compose exec gateway sh         # shell into the running gateway container
docker compose exec gateway nginx -t   # check nginx.conf parses, from outside or inside
```

### Applying a config change

`nginx.conf` is bind-mounted read-only, so you edit it on your Mac, then tell
the container to pick it up:

```bash
docker compose exec gateway nginx -t         # ALWAYS do this first
docker compose restart gateway               # blunt: drops in-flight connections
docker compose exec gateway nginx -s reload  # graceful: old workers finish, new ones take over
```

Skipping `nginx -t` is the single most common way to break the lab — a typo
leaves the gateway dead and every request hanging, and the parse error
scrolls past in the logs instead of stopping you up front.

### Resource usage / full reset

```bash
docker stats                                                      # live CPU/mem per container
docker compose down -v && docker compose up -d --force-recreate   # nuke and rebuild from scratch
```

---

## What's running

| Service | Host port | Image | Role |
|---|---|---|---|
| `gateway` | 8080, 8443 | `nginx:1.27-alpine` | the thing you edit |
| `echo1` | 9001 | `mendhak/http-https-echo` | echoes the request back as JSON |
| `echo2` | 9002 | `mendhak/http-https-echo` | second instance, for balancing |
| `random-status-code-with-caching` | 9003 | `mccutchen/go-httpbin` | `/delay`, `/cache`, `/etag`, `/bytes` — plus `/status` |
| `random-status-code-1` | 9004 | `mccutchen/go-httpbin` | same image, used for `/status/200:0.5,500:0.5` |
| `random-status-code-2` | 9005 | `mccutchen/go-httpbin` | second instance, for retries |
| `toxiproxy` | 8474 | `ghcr.io/shopify/toxiproxy` | network damage, admin API |

Every backend is published directly on the host as well as being reachable
through the gateway. That's the most useful property of this lab: you can always
diff "through the proxy" against "straight to the service".

All images are arm64-native, so nothing runs under emulation on Apple Silicon.

### Gateway routes

| Route | Goes to | Used by |
|---|---|---|
| `/lab1/` | echo1, no headers set | lab 01 |
| `/lab1-fixed/` | echo1, headers set properly | lab 01 |
| `/match/...` | returns which location matched | lab 02 |
| `/strip/`, `/nostrip/` | echo pool, different upstream paths | lab 02 |
| `/balanced/` | echo pool (balanced) | lab 03 |
| `/network-chaos/` | random-status-code-with-caching, via toxiproxy | labs 04, 08 |
| `/flaky/` | flaky pool (random-status-code-1/-2) | lab 04 |
| `/cached/` | random-status-code-with-caching, via toxiproxy | lab 05 |
| `/limited/`, `/limited-by-key/`, `/concurrent/` | echo pool / random-status-code-with-caching | lab 06 |
| `/healthz` | the gateway itself | everywhere |

---

## The labs

| # | Lab | You'll learn |
|---|---|---|
| 00 | [Orientation](labs/00-orientation.md) | the pieces, the log format, the edit loop |
| 01 | [What a proxy does](labs/01-what-a-proxy-does.md) | Host, `X-Forwarded-For`, hop-by-hop headers, header forgery |
| 02 | [Routing](labs/02-routing.md) | location precedence, the trailing-slash trap, rewrites, vhosts |
| 03 | [Load balancing](labs/03-load-balancing.md) | round-robin vs `least_conn`, weights, sticky sessions, health checks |
| 04 | [Timeouts and retries](labs/04-timeouts-and-retries.md) | why 60s defaults kill you, retry storms, idempotency |
| 05 | [Caching](labs/05-caching.md) | cache keys as a security boundary, stampedes, serving stale |
| 06 | [Rate limiting](labs/06-rate-limiting.md) | token buckets, burst vs nodelay, why keying on IP breaks |
| 07 | [TLS termination](labs/07-tls-termination.md) | encryption vs identity, SNI, HSTS, mTLS |
| 08 | [Network chaos](labs/08-network-chaos.md) | slow vs down, tail latency, defenses under real failure |

---

## Tools

```bash
bin/loadtest.sh /balanced/ 100 10      # 100 requests, 10 concurrent, tallied
bin/loadtest.sh '/flaky/status/200:0.5,500:0.5' 50
bin/setup-certs.sh                  # self-signed cert for lab 07

bin/chaos.sh status                 # what's currently broken
bin/chaos.sh latency 2000           # add 2s to every /network-chaos/ response
bin/chaos.sh slow 1024              # throttle to 1KB/s
bin/chaos.sh timeout                # accept connections, never respond
bin/chaos.sh down                   # refuse connections
bin/chaos.sh reset                  # undo everything
```

Chaos only affects `/network-chaos/` and `/cached/`. Everything else is your control
group.

---

## Layout

```
api-platform-lab/
├── docker-compose.yml           the whole environment
├── nginx/
│   ├── nginx.conf               the one file you edit
│   ├── snippets/
│   │   └── proxy-headers.conf   the headers a proxy owes its backends
│   └── certs/                   generated by bin/setup-certs.sh
├── toxiproxy/toxiproxy.json     which connections can be damaged
├── bin/                         loadtest, chaos, certs
└── labs/                        00-08, in order
```

Every commented-out block in `nginx.conf` is tagged with the lab that turns it
on, e.g. `# LAB 4 step 3:`. You can also read the file top to bottom as an
annotated tour.

---

## Troubleshooting

**`Cannot connect to the Docker daemon`** — Docker Desktop isn't running. Launch
it and wait for the menu bar icon to settle.

**`port is already allocated`** — something else owns 8080, 8443, 9001–9005, or
8474. Find it with `lsof -i :8080`, or change the left-hand side of the port
mapping in `docker-compose.yml`.

**Gateway won't start after an edit** — you have a config error:
```bash
docker compose logs gateway | tail -20
docker compose exec gateway nginx -t
```
If the container is dead, `nginx -t` can't run in it. Fix the file and
`docker compose up -d gateway`.

**`host not found in upstream "echo2"`** — you restarted the gateway while a
backend container was stopped. nginx resolves upstream hostnames once, at
startup, and refuses to start if one is missing. Start the backend first
(`docker compose start echo2`), then the gateway. This trips people up
constantly in containerized setups; the production workaround is a `resolver`
directive plus a variable in `proxy_pass`, which forces runtime DNS lookups.

**Every request hangs** — usually leftover chaos. `bin/chaos.sh reset`.

**502 on `/balanced/`** — a backend is stopped. `docker compose ps`, then
`docker compose start echo2`.

**All sequential requests go to one backend** — you removed `zone echo_pool 64k;`
from the upstream block. Without it every nginx worker keeps a separate
round-robin counter, and sequential requests each land on a different idle
worker that starts from the first backend. Lab 03 step 1b covers this.

**Changes to `nginx.conf` don't take effect** — it's mounted read-only into the
container; edit it on your Mac, not inside the container, then restart the
gateway.

---

## Security posture of the lab itself

Running a compose file means executing code written by strangers. What this one
does about that:

- **Every image is pinned by digest**, not just tag — `nginx:1.27-alpine@sha256:65645c…`.
  A tag is a mutable pointer the publisher can repush; a digest is immutable
  content addressing. To refresh one deliberately:
  ```bash
  docker pull <image>:<tag> && docker image inspect <image>:<tag> --format '{{index .RepoDigests 0}}'
  ```
  Use the multi-arch *index* digest that returns, or the file breaks on non-arm64
  machines.
- **All ports bind to `127.0.0.1`** — nothing here is reachable from your network.
- **`cap_drop: [ALL]`** on every container, with only the capabilities nginx
  genuinely needs added back, plus `no-new-privileges` and memory limits.
- **No Dockerfiles** — nothing is built, so no `RUN` executes at build time.
- **No `--privileged`, no docker socket mount, no host networking.**
- **Bind mounts are `:ro` and confined to this directory** — your home folder is
  not exposed to any container.

Provenance, stated plainly: `nginx` is a Docker Official Image and `toxiproxy`
comes from Shopify's GitHub org. `go-httpbin` and `http-https-echo` are
individuals' repositories — both well-known open-source projects, both still
strangers on the internet. Scan any of them with `docker scout cves <image>`.

## What this deliberately doesn't cover

nginx open source has no JWT validation, no consumer or credential model, no
per-plan quotas, no `X-RateLimit-*` headers, no active health checks, and no
per-route metrics endpoint. Those are the *API management* half of the subject,
and lab 08 ends with the table showing exactly where the walls are.

The natural phase 2 is to put Kong (declarative YAML, plugins per route) in
front of these same backends and do the comparison directly — same upstreams,
same curl commands, a very different config model.
