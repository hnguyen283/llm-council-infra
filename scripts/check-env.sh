#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
failed=0

for env_file in "$ROOT/env/defaults.env" "$ROOT/env/modes/http.env" "$ROOT/env/modes/https.env" "$ROOT"/options/*/option.env; do
  [ -f "$env_file" ] || continue
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      ""|\#*) continue ;;
    esac
    case "$key" in
      *PASSWORD*|*SECRET*|*TOKEN*|*PRIVATE*|*PEM*|*API_KEY*|*HMAC_KEY*|*SIGNING_KEY*)
        if [ -n "${value:-}" ]; then
          echo "ERROR: tracked secret-like value is non-empty in $env_file: $key" >&2
          failed=1
        fi
        ;;
    esac
  done < "$env_file"
done

[ "$failed" -eq 0 ]
echo "Environment contract check passed."
