#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SSL_DIR="$ROOT/ssl"
mkdir -p "$SSL_DIR"

if command -v mkcert >/dev/null 2>&1; then
  echo "Generating locally trusted certificate with mkcert."
  (cd "$SSL_DIR" && mkcert -cert-file cert.pem -key-file key.pem localhost 127.0.0.1 ::1)
  exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: Install mkcert or OpenSSL to generate local TLS material." >&2
  exit 1
fi

echo "mkcert not found. Generating self-signed certificate with OpenSSL."
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout "$SSL_DIR/key.pem" \
  -out "$SSL_DIR/cert.pem" \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
