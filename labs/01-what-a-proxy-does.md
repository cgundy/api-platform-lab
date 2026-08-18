# Lab 01 — What a proxy actually does

The single most useful thing to understand: a reverse proxy does **not** forward
your request unchanged. It terminates your connection, builds a *new* request,
and opens a *separate* connection to the backend. Everything else in this lab
follows from that.

## Step 1 — the baseline

Ask the backend directly, bypassing the gateway entirely:

```bash
curl -s http://localhost:9001/hello | python3 -m json.tool
```

Look at `headers` and `path`. That's the truth about your request.

## Step 2 — the same request through a naked proxy

`/lab1/` in `nginx.conf` is a deliberately minimal `proxy_pass` — one line, no
header handling:

```bash
curl -s http://localhost:8080/lab1/hello | python3 -m json.tool
```

Diff the two outputs. Four things changed, and every one of them breaks
something real:

**`host` is now `users1:8080`.** nginx defaulted it to the upstream's address.
Your backend has lost all knowledge of the domain the user typed. Anything that
generates absolute URLs (password reset links, pagination `next` URLs,
redirects, OAuth callbacks) will now emit `http://users1:8080/...` and hand it
to a browser that cannot resolve it. Virtual hosting — several sites behind one
IP — becomes impossible.

**The source IP is the gateway's, not yours.** From the backend's perspective
every request in the world now comes from one address. Rate limiting by IP,
geolocation, audit logs, and abuse blocking are all silently dead.

**`connection: close` appeared.** nginx speaks HTTP/1.0 to upstreams unless told
otherwise, so it opens a brand-new TCP connection per request and tears it down
after. At low volume you won't notice. At high volume you're paying a handshake
per request and burning through ephemeral ports.

**There's no way to correlate logs.** The gateway logged a request, the backend
logged a request, and nothing links them.

## Step 3 — the fix

`/lab1-fixed/` is the identical route with
`include /etc/nginx/snippets/proxy-headers.conf` added:

```bash
curl -s http://localhost:8080/lab1-fixed/hello | python3 -m json.tool
```

Now `host` is `localhost`, and the backend gets `x-real-ip`,
`x-forwarded-for`, `x-forwarded-proto` and `x-request-id`. Open
[`nginx/snippets/proxy-headers.conf`](../nginx/snippets/proxy-headers.conf) —
each line has a comment explaining what breaks without it.

The `X-Forwarded-*` family exists purely because the proxy destroyed
information that the backend needs, so it has to be re-attached out of band.
They aren't part of the HTTP standard proper; they're a convention that grew up
around proxies. (RFC 7239 tried to replace all of them with a single
`Forwarded:` header. Almost nobody uses it.)

## Step 4 — hop-by-hop headers

Try to make nginx forward a `Connection` header:

```bash
curl -s -H 'Connection: keep-alive' -H 'X-Mine: kept' \
  http://localhost:8080/lab1-fixed/hello | python3 -m json.tool
```

`x-mine` arrives. `connection` did not — nginx replaced it. `Connection`,
`Keep-Alive`, `Transfer-Encoding`, `Upgrade` and `TE` are **hop-by-hop**
headers: they describe *this* TCP connection, not the message. A proxy must
consume them and not pass them on, because the connection on the other side is
a different connection with different properties.

This is also why WebSockets need explicit config in nginx — `Upgrade` is
hop-by-hop, so it gets eaten unless you deliberately re-add it.

## Step 5 — the security half of X-Forwarded-For

Now forge the header:

```bash
curl -s -H 'X-Forwarded-For: 1.2.3.4' \
  http://localhost:8080/lab1-fixed/hello | python3 -m json.tool
```

The backend receives `1.2.3.4, 172.18.0.1` — your lie, with the real address
appended. That's `$proxy_add_x_forwarded_for` doing its job: it *appends* rather
than replaces, so a chain of proxies stays intact.

But consider what that means. If your backend does
`client_ip = request.headers['X-Forwarded-For'].split(',')[0]` — which is the
obvious-looking implementation, and extremely common — then **any client can
set their own IP address**. IP-based rate limits, IP allowlists for admin
panels, and "log in from a new location" checks all become trivially bypassable.

The rule: only the *rightmost* entries are trustworthy, and only as many as you
have proxies you control. An internet-facing gateway should either strip
inbound `X-Forwarded-For` and set it fresh, or use nginx's `realip` module with
an explicit `set_real_ip_from` list of trusted proxy addresses. Trusting the
whole header because it looks official is the bug.

## Step 6 — see the two connections

```bash
docker compose exec gateway wget -qO- http://users1:8080/hello
```

That worked from inside the container network, using a hostname (`users1`) that
does not exist on your Mac — Docker's embedded DNS resolves service names on
the compose network. Your `curl` to `localhost:8080` and nginx's connection to
`users1:8080` are two entirely separate TCP connections with different source
addresses, different lifetimes, and potentially different HTTP versions.

## What you learned

- A proxy rebuilds the request; it does not relay it.
- Host, source IP, and connection semantics are destroyed by default and must be
  deliberately restored.
- `X-Forwarded-*` headers are client-controlled input until a proxy you trust
  overwrites them.
- Hop-by-hop headers stop at every hop, by design.

---

Prev: [00 — orientation](00-orientation.md) · Next: [02 — routing](02-routing.md)
