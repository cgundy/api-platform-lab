# Lab 07 — TLS termination

"Termination" means TLS stops at the gateway: it decrypts, inspects, routes, and
then speaks plain HTTP to your backends. That's what makes routing on paths and
headers possible at all — an encrypted stream is opaque.

## Step 1 — make a certificate

```bash
bin/setup-certs.sh
```

Look at what you made:

```bash
openssl x509 -in nginx/certs/lab.crt -noout -subject -issuer -dates
```

Subject and issuer are the same — that's what "self-signed" means. There's no
chain to a certificate authority anyone trusts, so the certificate vouches only
for itself.

## Step 2 — turn on HTTPS

Uncomment the entire `server { listen 443 ssl; ... }` block at the bottom of
`nginx/nginx.conf`, then:

```bash
docker compose exec gateway nginx -t
docker compose restart gateway
curl -sS https://localhost:8443/headers
```

Note `-sS` rather than plain `-s`. With `-s` alone curl suppresses its own error
message, so a failed TLS handshake prints *nothing at all* and looks like a hang
— `-S` puts the error back. Worth remembering generally: `-s` in a script hides
the reason things broke.

It fails, and that failure is the lesson:

```
curl: (60) SSL certificate problem: self signed certificate
```

Encryption succeeded. **Identity** failed. curl established an encrypted channel
perfectly well, then refused to talk over it because nothing proves the server
is who it claims. Encryption without identity verification buys you very little
— an attacker who intercepts the connection can present their own certificate
and encrypt the traffic to themselves.

## Step 3 — proceed anyway, two ways

The blunt way:

```bash
curl -k https://localhost:8443/headers
```

`-k` disables verification entirely. Fine here, a serious problem in any script
you plan to keep — it's the single most common way TLS gets silently disabled in
production code.

The correct way — trust *this specific* certificate:

```bash
curl --cacert nginx/certs/lab.crt https://localhost:8443/headers | head -5
```

That's certificate pinning, and it's how internal services legitimately talk to
each other without a public CA.

## Step 4 — what the backend can see

```bash
curl -k -s https://localhost:8443/headers
```

Look at `x-forwarded-proto: https`. The backend received a **plain HTTP**
request — the gateway decrypted it. The only way the app knows the user was on
HTTPS is that header, which is why lab 1's header work matters here.

This has a real consequence: an app that decides "am I secure?" by checking
whether its own connection is TLS will always answer no behind a terminating
proxy, and will redirect-loop forever. Frameworks have a "trust proxy" setting
for exactly this, and it must only be enabled when a proxy you control is
actually in front — otherwise clients can forge `X-Forwarded-Proto: https` and
convince your app that a plaintext request was secure.

## Step 5 — inspect the handshake

```bash
curl -kv https://localhost:8443/healthz 2>&1 | grep -iE 'SSL connection|TLS|ALPN|subject|issuer'
```

You'll see the negotiated TLS version and cipher, and ALPN choosing the protocol
(`h2` if HTTP/2 negotiated). Or use openssl directly:

```bash
openssl s_client -connect localhost:8443 -servername localhost </dev/null 2>/dev/null | head -25
```

`-servername` sets **SNI** — the hostname sent *unencrypted* at the start of the
handshake, so the server knows which certificate to present before encryption
begins. SNI is what lets one IP host many HTTPS sites. It's also why "HTTPS
hides which site you visited" isn't quite true: SNI leaks the hostname in
plaintext (ECH is the fix, still rolling out).

## Step 6 — force HTTPS

Uncomment `/secure/` in the port-80 server block:

```nginx
location /secure/ {
    return 301 https://$host:8443$request_uri;
}
```

```bash
docker compose restart gateway
curl -si http://localhost:8080/secure/anything | head -3
curl -kL http://localhost:8080/secure/headers | head -5
```

The first shows the 301; `-L` follows it over to TLS.

A redirect only helps *after* one plaintext request already happened, and that
request could have been intercepted. HSTS closes the gap — uncomment in the 443
block:

```nginx
add_header Strict-Transport-Security "max-age=31536000" always;
```

```bash
docker compose restart gateway
curl -ks -D- https://localhost:8443/healthz -o /dev/null | grep -i strict
```

Once a browser sees that header it refuses plaintext to this host for a year,
without asking the server. Which means: **if you enable HSTS and later can't
maintain a valid certificate, you have locked users out of your site**, and
there's no way to reach them to say otherwise. Start with a short `max-age`.

## Step 7 — what you'd change for real

- **Real certificates.** Let's Encrypt via certbot or the ACME protocol, renewed
  automatically. Expired certificates remain a leading cause of outages, and
  it's always because renewal wasn't automated.
- **`ssl_protocols TLSv1.2 TLSv1.3;`** — already set. TLS 1.0/1.1 are broken and
  should never be enabled.
- **OCSP stapling** — the gateway fetches its own revocation proof rather than
  making every client ask the CA. Faster and better for privacy.
- **`ssl_session_cache`** — already on. Resumption skips a full handshake, which
  matters a lot on mobile.
- **mTLS**, where the *client* also presents a certificate:

  ```nginx
  ssl_client_certificate /etc/nginx/certs/ca.crt;
  ssl_verify_client on;
  ```

  This is how service meshes authenticate services to each other, and how you'd
  secure a partner API without shared secrets.

## What you learned

- Encryption and identity are separate; TLS gives the first easily, the second
  is the hard part.
- Termination means backends see plaintext and learn the original scheme only
  from a header they must be told to trust.
- SNI travels in the clear, before encryption starts.
- HSTS is powerful and effectively irreversible for its lifetime.
- `-k` in a script is a bug, not a workaround.

---

Prev: [06 — rate limiting](06-rate-limiting.md) · Next: [08 — network chaos](08-network-chaos.md)
