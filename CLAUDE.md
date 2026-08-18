# CLAUDE.md

Guidance for Claude Code (or anyone else) working in this repo.

## What this is

A local nginx API gateway lab: seven Docker containers, zero application code.
See [README.md](README.md) for the full architecture, port table, and
`labs/00-orientation.md` for a guided walkthrough. This file only covers
things that aren't obvious from reading the code.

## Editing `nginx/nginx.conf`

The gateway container mounts this file read-only via a bind mount
(`docker-compose.yml`). After editing it:

```bash
docker compose exec gateway nginx -t   # always check syntax before restarting
docker compose restart gateway
```

**Known gotcha:** the bind mount can lag briefly after a save — `nginx -t`
may fail with something like `unexpected end of file, expecting "}"` even
though the file on disk is fine (the container is reading a stale/truncated
copy). If `nginx -t` fails right after an edit and the file looks correct,
run `docker compose restart gateway` and retest before assuming the edit
itself is broken.

## `proxy_next_upstream` default behavior

nginx's default (`proxy_next_upstream error timeout`) silently retries a
failed request against the next upstream in the pool — a dead backend never
surfaces as an error to the client, it just adds latency. This is *on*
unless a `location` block explicitly disables it.

`/balanced/` (`nginx.conf`) has `proxy_next_upstream off;` set deliberately,
so that killing a backend (`docker compose stop echo2`) actually produces a
502 for Lab 3 Step 5, instead of being masked. Keep this in mind if you add
new locations that proxy to a pool with more than one server — decide
explicitly whether failures should retry silently or surface.

## Security review before first run

This lab pulls container images from a mix of Docker Official Images and
smaller community publishers, and binds several ports to the host. Before
running `docker compose up` for the first time (or after pulling changes
that touch `docker-compose.yml`), check:

- **Digest pinning** — every `image:` line should pin
  `image:tag@sha256:...`, not just a mutable tag. Tags can be repushed by
  the publisher at any time; a digest can't.
- **Image provenance** — note which images are Docker Official Images vs.
  community/personal repos.
- **Host exposure** — port bindings should be `127.0.0.1:PORT:PORT`, not
  bound to `0.0.0.0` (which is reachable from the whole LAN/wifi network).
- **Mounts and privileges** — check for bind mounts outside the project
  directory, `:rw` vs `:ro`, `/var/run/docker.sock`, `--privileged`,
  `cap_add`, `network_mode: host`.

Surface anything that doesn't meet this bar before running, rather than
after — the point is to decide whether to run at all.

## Working state

Commands assume you're in this directory (`docker compose` reads
`docker-compose.yml` from cwd). See the "Working with the containers"
section of `README.md` for the fuller command reference and the `Makefile`
shortcuts (`make help`).
