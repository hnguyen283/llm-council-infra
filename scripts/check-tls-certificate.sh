#!/usr/bin/env sh
set -eu

certificate_path=${1:?certificate path is required}
expected_host=${2:?expected host is required}

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: OpenSSL is required to validate the HTTPS certificate." >&2
  exit 1
fi

openssl x509 -in "$certificate_path" -noout -checkhost "$expected_host"
if ! openssl verify -verify_hostname "$expected_host" "$certificate_path" >/dev/null 2>&1; then
  echo "ERROR: HTTPS certificate is not trusted by OpenSSL for $expected_host." >&2
  echo "Install the mkcert root in this environment's trust store, then retry." >&2
  exit 1
fi

echo "VALID: HTTPS certificate matches $expected_host and is locally trusted."
