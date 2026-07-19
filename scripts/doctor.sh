#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPTION=${1:-prod-full-local-http}
OPTION_DIR="$ROOT/options/$OPTION"

if [ ! -f "$OPTION_DIR/option.env" ]; then
  echo "ERROR: Unknown option \"$OPTION\"." >&2
  exit 1
fi

echo "=== Docker ==="
docker compose version
docker info >/dev/null

MODE=http
if grep -qi '^PUBLIC_SCHEME=https' "$OPTION_DIR/option.env"; then
  MODE=https
fi

echo
echo "=== Option manifest ==="
"$ROOT/scripts/config.sh" "$OPTION"

find_value() {
  target=$1
  value=$(printenv "$target" 2>/dev/null || true)
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi
  resolved_value=
  for env_file in "$ROOT/env/defaults.env" "$ROOT/env/workspace.env" "$ROOT/env/modes/$MODE.env" "$OPTION_DIR/option.env" "$OPTION_DIR/.env" "$ROOT/env/local.user.override.env"; do
    [ -f "$env_file" ] || continue
    value=$(awk -F= -v k="$target" '$1 == k {value=substr($0, length(k) + 2); sub(/\r$/, "", value); print value}' "$env_file" | tail -n 1)
    if [ -n "$value" ]; then
      resolved_value=$value
    fi
  done
  printf '%s' "$resolved_value"
  return 0
}

echo
echo "=== Required secret presence ==="
missing=0
required_keys="POSTGRES_PASSWORD ACCOUNT_DB_PASSWORD PROMPT_DB_PASSWORD VALKEY_PASSWORD AUTH_JWT_PRIVATE_KEY_PEM AUTH_JWT_PUBLIC_KEYS_PEM AUTH_GOOGLE_SIGNUP_SECRET ACCOUNT_INTERNAL_SERVICE_TOKEN TENANT_NAMESPACE_HMAC_KEY"
if [ "$(find_value GRAPHRAG_ENABLED)" = "true" ]; then
  required_keys="$required_keys GRAPHRAG_DB_PASSWORD"
fi
for key in $required_keys; do
  value=$(find_value "$key")
  if [ -z "$value" ]; then
    echo "MISSING: $key"
    missing=1
  else
    echo "PRESENT: $key (environment compatibility)"
  fi
done

check_gateway_key() {
  key=$1
  file_name=$2
  if [ -n "$(find_value "$key")" ]; then
    echo "PRESENT: $key (environment compatibility)"
  elif [ -s "$ROOT/secrets/local/api-gateway/$file_name" ]; then
    echo "PRESENT: $key (file-backed)"
  else
    echo "MISSING: $key (environment value or file-backed secret)"
    missing=1
  fi
}
check_gateway_key GATEWAY_INTERNAL_PRIVATE_KEY_PEM private-key.pem
check_gateway_key GATEWAY_INTERNAL_PUBLIC_KEYS_PEM public-keys.pem

tls_termination=$(find_value TLS_TERMINATION)
local_tls_trust_required=$(find_value LOCAL_TLS_TRUST_REQUIRED)
[ -n "$local_tls_trust_required" ] || local_tls_trust_required=true
if [ "$MODE" = "https" ] && [ "$tls_termination" != "cloudflare" ]; then
  cert_dir=$(find_value HTTPS_CERT_DIR)
  case "$cert_dir" in
    /*) resolved_cert_dir=$cert_dir ;;
    *) resolved_cert_dir="$ROOT/compose/$cert_dir" ;;
  esac
  if [ ! -s "$resolved_cert_dir/cert.pem" ] || [ ! -s "$resolved_cert_dir/key.pem" ]; then
    echo "MISSING: HTTPS cert.pem/key.pem"
    missing=1
  else
    public_host=$(find_value PUBLIC_HOST)
    if [ "$local_tls_trust_required" = "true" ]; then
      if ! sh "$ROOT/scripts/check-tls-certificate.sh" "$resolved_cert_dir/cert.pem" "$public_host"; then
        echo "INVALID: HTTPS certificate identity or local trust"
        missing=1
      fi
    else
      if sh "$ROOT/scripts/check-tls-certificate.sh" "$resolved_cert_dir/cert.pem" "$public_host" >/dev/null 2>&1; then
        echo "VALID: optional HTTPS certificate identity/local trust check passed"
      else
        echo "OPTIONAL: HTTPS certificate identity/local trust did not pass; continuing because LOCAL_TLS_TRUST_REQUIRED=false"
      fi
    fi
  fi
fi
if [ "$MODE" = "https" ] && [ "$tls_termination" = "cloudflare" ]; then
  echo "PRESENT: public TLS terminates at Cloudflare; local origin uses the private Compose network"
fi

if [ "$(find_value TUNNEL_ENABLED)" = "true" ]; then
  if [ -z "$(find_value CLOUDFLARED_TUNNEL_TOKEN)" ]; then
    echo "MISSING: CLOUDFLARED_TUNNEL_TOKEN"
    missing=1
  else
    echo "PRESENT: CLOUDFLARED_TUNNEL_TOKEN"
  fi
  if [ "$(find_value LOCAL_SERVICE_MAPPING)" != "http://localhost:8080" ]; then
    echo "INVALID: LOCAL_SERVICE_MAPPING must match the remotely managed Cloudflare origin"
    missing=1
  else
    echo "PRESENT: Cloudflare origin contract http://localhost:8080"
  fi
fi

if [ "$missing" -ne 0 ]; then
  echo
  echo "ERROR: Required option prerequisites are missing." >&2
  exit 1
fi

echo
echo "Doctor passed for $OPTION."
