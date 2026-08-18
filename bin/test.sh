#!/usr/bin/env bash
# Smoke test: does the stack come up and answer?
#
# usage:
#   bin/test.sh        check the stack that is already running
#   bin/test.sh --up   bring it up first, then check (this is what CI does)
#
# Deliberately shallow. This answers "is the lab broken?", not "does the lab
# still teach what it claims?" - it should stay fast and boring.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; N=$'\033[0m'; else G=""; R=""; N=""; fi
ok()  { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"
        [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }

if [ "${1:-}" = "--up" ]; then
  echo "starting the stack..."
  # --wait blocks until the gateway's healthcheck passes, and exits non-zero
  # if it never does - so a broken config fails right here.
  docker compose up -d --wait || { echo "compose up failed"; docker compose logs --tail 50; exit 1; }
elif [ "${1:-}" != "" ]; then
  sed -n '2,9p' "$0"; exit 2
fi

echo
echo "smoke test"

# 1. the compose file itself is valid
if docker compose config -q >/tmp/dc.$$ 2>&1; then ok "docker-compose.yml is valid"
else bad "docker-compose.yml is valid" "$(head -3 /tmp/dc.$$)"; fi
rm -f /tmp/dc.$$

# 2. every container is up
for c in lab-gateway lab-users1 lab-users2 lab-orders lab-flaky1 lab-flaky2 lab-toxiproxy; do
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then ok "$c running"
  else bad "$c running"; fi
done

# 3. the gateway's own healthcheck is passing
health=$(docker inspect lab-gateway --format '{{.State.Health.Status}}' 2>/dev/null || echo unreachable)
if [ "$health" = "healthy" ]; then ok "gateway healthcheck passing"
else bad "gateway healthcheck passing" "status: $health"; fi

# 4. it actually serves traffic
sc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8080/healthz)
if [ "$sc" = "200" ]; then ok "gateway answers on :8080"
else bad "gateway answers on :8080" "got HTTP $sc"; fi

printf '\n%s%d passed%s, %s%d failed%s\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N"
[ "$FAIL" -eq 0 ]
