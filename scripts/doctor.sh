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
  for env_file in "$ROOT/env/defaults.env" "$ROOT/env/workspace.env" "$ROOT/env/modes/$MODE.env" "$OPTION_DIR/option.env" "$OPTION_DIR/.env" "$ROOT/env/local.user.override.env"; do
    [ -f "$env_file" ] || continue
    value=$(awk -F= -v k="$target" '$1 == k {print substr($0, length(k) + 2)}' "$env_file" | tail -n 1)
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
  done
  return 0
}

echo
echo "=== Required secret presence ==="
missing=0
required_keys="POSTGRES_PASSWORD ACCOUNT_DB_PASSWORD PROMPT_DB_PASSWORD VALKEY_PASSWORD AUTH_JWT_PRIVATE_KEY_PEM AUTH_JWT_PUBLIC_KEYS_PEM GATEWAY_INTERNAL_PRIVATE_KEY_PEM GATEWAY_INTERNAL_PUBLIC_KEYS_PEM ACCOUNT_INTERNAL_SERVICE_TOKEN TENANT_NAMESPACE_HMAC_KEY"
if [ "$(find_value GRAPHRAG_ENABLED)" = "true" ]; then
  required_keys="$required_keys GRAPHRAG_DB_PASSWORD"
fi
for key in $required_keys; do
  value=$(find_value "$key")
  if [ -z "$value" ]; then
    echo "MISSING: $key"
    missing=1
  else
    echo "PRESENT: $key"
  fi
done

if [ "$missing" -ne 0 ]; then
  echo
  echo "ERROR: Required secrets are missing. Put local values in an untracked env file." >&2
  exit 1
fi

echo
echo "Doctor passed for $OPTION."
