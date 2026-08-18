#!/usr/bin/env bash
# Generate a self-signed certificate for the gateway (lab 07).
#
# Self-signed means no public certificate authority vouches for it, so curl and
# browsers will refuse it until you pass -k / click through. That refusal IS the
# lesson: TLS gives you encryption for free, but identity is the hard part.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS="$ROOT/nginx/certs"

mkdir -p "$CERTS"

echo "generating a self-signed cert for localhost..."

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$CERTS/lab.key" \
  -out    "$CERTS/lab.crt" \
  -days   365 \
  -subj   "/CN=localhost/O=API Platform Lab" \
  -addext "subjectAltName=DNS:localhost,DNS:gateway,IP:127.0.0.1"

# nginx runs its workers as an unprivileged user and must be able to read these.
chmod 644 "$CERTS/lab.crt" "$CERTS/lab.key"

echo
echo "wrote:"
echo "  $CERTS/lab.crt"
echo "  $CERTS/lab.key"
echo
echo "inspect it with:"
echo "  openssl x509 -in nginx/certs/lab.crt -noout -text | head -20"
echo
echo "next: uncomment the 443 server block at the bottom of nginx/nginx.conf,"
echo "then run: docker compose restart gateway"
