#!/usr/bin/env bash
# Fire N requests at a URL with C of them in flight, and tally the status codes.
# No dependencies beyond curl and xargs - both already on your Mac.
#
# usage: bin/loadtest.sh <path-or-url> [count] [concurrency]
#
# examples:
#   bin/loadtest.sh /balanced/                     100 requests, 1 at a time
#   bin/loadtest.sh /limited/ 40 10             40 requests, 10 in flight
#   bin/loadtest.sh '/flaky/status/200:0.5,500:0.5' 50
#
# A bare path is assumed to be on the gateway (http://localhost:8080).
# Quote any URL containing ',' or '?' or the shell will mangle it.

set -uo pipefail

TARGET="${1:-/balanced/}"
COUNT="${2:-100}"
CONC="${3:-1}"

case "$TARGET" in
  http://*|https://*) URL="$TARGET" ;;
  /*)                 URL="http://localhost:8080$TARGET" ;;
  *)                  URL="http://localhost:8080/$TARGET" ;;
esac

echo "$COUNT requests to $URL, concurrency $CONC"
echo

START=$(date +%s)

RESULTS=$(
  seq 1 "$COUNT" | xargs -P "$CONC" -I{} \
    curl -s -o /dev/null -w '%{http_code} %{time_total}\n' "$URL"
)

END=$(date +%s)
ELAPSED=$(( END - START ))
[ "$ELAPSED" -eq 0 ] && ELAPSED=1

echo "status codes:"
echo "$RESULTS" | awk '{print $1}' | sort | uniq -c | sort -rn | sed 's/^/  /'

echo
echo "latency:"
# sort -n does the ordering so awk only has to index - the mean tells you very
# little on its own, which is the point lab 08 makes about tail latency.
echo "$RESULTS" | awk '{print $2}' | sort -n | awk '
  { t[NR] = $1; sum += $1 }
  END {
    n = NR
    if (n == 0) { print "  no samples"; exit }
    printf "  mean  %.3fs\n", sum / n
    printf "  p50   %.3fs\n", t[int((n - 1) * 0.50) + 1]
    printf "  p95   %.3fs\n", t[int((n - 1) * 0.95) + 1]
    printf "  p99   %.3fs\n", t[int((n - 1) * 0.99) + 1]
    printf "  max   %.3fs\n", t[n]
  }'

echo
echo "took ${ELAPSED}s (~$(( COUNT / ELAPSED )) req/s)"
