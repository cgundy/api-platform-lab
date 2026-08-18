#!/usr/bin/env bash
# Break the network between the gateway and the "orders" service, at runtime.
#
# Toxiproxy sits on the wire and applies "toxics" - latency, bandwidth caps,
# blackholes. Nothing restarts; the damage applies to the next packet. This is
# how you find out what your timeout settings actually do.
#
# Only /orders/ and /cached/ traffic goes through toxiproxy. /users/ and
# /flaky/ talk to their backends directly and are unaffected.

set -euo pipefail

API="${TOXIPROXY_API:-http://localhost:8474}"
PROXY="orders"

usage() {
  cat <<'EOF'
usage: bin/chaos.sh <command> [args]

  status              show proxies and the toxics currently applied
  latency <ms>        add <ms> of delay to every response   (default 1000)
  slow <bytes/s>      throttle the downstream to <bytes/s>  (default 1024)
  timeout             accept the connection, then never answer
  down                refuse connections entirely (backend "offline")
  up                  bring the connection back
  reset               remove all toxics, leave the proxy enabled

examples:
  bin/chaos.sh latency 3000
  curl -s -o /dev/null -w '%{time_total}s\n' http://localhost:8080/orders/get
  bin/chaos.sh reset
EOF
}

toxics() { curl -sS "$API/proxies/$PROXY/toxics"; }

add_toxic() {
  curl -sS -X POST "$API/proxies/$PROXY/toxics" \
    -H 'Content-Type: application/json' -d "$1"
  echo
}

del_toxic() {
  curl -sS -X DELETE "$API/proxies/$PROXY/toxics/$1" >/dev/null 2>&1 || true
}

clear_all() {
  for t in lab_latency lab_bandwidth lab_timeout; do del_toxic "$t"; done
}

case "${1:-}" in
  status)
    echo "--- proxies ---"
    curl -sS "$API/proxies"; echo
    echo "--- toxics on '$PROXY' ---"
    toxics; echo
    ;;

  latency)
    ms="${2:-1000}"
    clear_all
    add_toxic "{\"name\":\"lab_latency\",\"type\":\"latency\",\"stream\":\"downstream\",\"attributes\":{\"latency\":$ms,\"jitter\":100}}"
    echo "orders now responds ${ms}ms slower (+/- 100ms jitter)"
    ;;

  slow)
    rate="${2:-1024}"
    clear_all
    add_toxic "{\"name\":\"lab_bandwidth\",\"type\":\"bandwidth\",\"stream\":\"downstream\",\"attributes\":{\"rate\":$rate}}"
    echo "orders downstream throttled to ${rate} bytes/sec"
    ;;

  timeout)
    clear_all
    add_toxic "{\"name\":\"lab_timeout\",\"type\":\"timeout\",\"stream\":\"downstream\",\"attributes\":{\"timeout\":0}}"
    echo "orders now accepts connections and never responds"
    echo "(this is the nasty failure mode - a refused connection fails fast,"
    echo " a hung one ties up a gateway worker until proxy_read_timeout)"
    ;;

  down)
    curl -sS -X POST "$API/proxies/$PROXY" \
      -H 'Content-Type: application/json' -d '{"enabled":false}' >/dev/null
    echo "orders is offline - connections are refused"
    ;;

  up)
    curl -sS -X POST "$API/proxies/$PROXY" \
      -H 'Content-Type: application/json' -d '{"enabled":true}' >/dev/null
    echo "orders is back online"
    ;;

  reset)
    clear_all
    curl -sS -X POST "$API/proxies/$PROXY" \
      -H 'Content-Type: application/json' -d '{"enabled":true}' >/dev/null
    echo "all toxics removed, orders enabled"
    ;;

  *)
    usage
    exit 1
    ;;
esac
