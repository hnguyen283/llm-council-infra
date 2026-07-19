#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case ${1:-} in
  "") SSL_DIR="$ROOT/ssl" ;;
  /*) SSL_DIR=$1 ;;
  *) SSL_DIR="$ROOT/$1" ;;
esac

if ! command -v mkcert >/dev/null 2>&1; then
  echo "ERROR: mkcert is required for browser-trusted local HTTPS." >&2
  echo "Install mkcert and its local root CA, then retry." >&2
  exit 1
fi

mkdir -p "$SSL_DIR"
if [ -e "$SSL_DIR/cert.pem" ] || [ -e "$SSL_DIR/key.pem" ]; then
  echo "ERROR: Refusing to overwrite existing TLS material in $SSL_DIR." >&2
  echo "Choose an empty output directory, for example: scripts/generate-local-tls.sh ssl-local" >&2
  exit 1
fi

echo "Generating locally trusted certificate with mkcert in $SSL_DIR."
(cd "$SSL_DIR" && mkcert -cert-file cert.pem -key-file key.pem localhost 127.0.0.1 ::1)
