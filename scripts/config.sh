#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPTION=${1:-prod-full-local-http}
OPTION_DIR="$ROOT/options/$OPTION"

if [ ! -f "$OPTION_DIR/option.env" ]; then
  echo "ERROR: Unknown option \"$OPTION\"." >&2
  echo "Available options:" >&2
  find "$ROOT/options" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; >&2
  exit 1
fi

if [ ! -f "$OPTION_DIR/compose.files" ]; then
  echo "Option: $OPTION"
  echo "This option does not render a local Compose stack."
  echo "Use the option-specific script documented in $OPTION_DIR/README.md."
  exit 0
fi

"$ROOT/scripts/check-env.sh"

MODE=http
if grep -qi '^PUBLIC_SCHEME=https' "$OPTION_DIR/option.env"; then
  MODE=https
fi

OUT_DIR="$ROOT/.generated/$OPTION"
mkdir -p "$OUT_DIR"

ENV_ARGS=""
ENV_LIST="$OUT_DIR/environment.layers.txt"
: > "$ENV_LIST"
add_env() {
  rel=$1
  abs="$ROOT/$rel"
  if [ -f "$abs" ]; then
    ENV_ARGS="$ENV_ARGS --env-file $abs"
    echo "$rel" >> "$ENV_LIST"
  fi
}
add_env "env/defaults.env"
add_env "env/workspace.env"
add_env "env/modes/$MODE.env"
add_env "options/$OPTION/option.env"
add_env "options/$OPTION/.env"
add_env "env/local.user.override.env"

FILE_ARGS=""
FILE_LIST="$OUT_DIR/compose.files.txt"
: > "$FILE_LIST"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ""|\#*) continue ;;
  esac
  file="$ROOT/$line"
  if [ ! -f "$file" ]; then
    echo "ERROR: Compose file not found: $line" >&2
    exit 1
  fi
  FILE_ARGS="$FILE_ARGS -f $file"
  echo "$line" >> "$FILE_LIST"
done < "$OPTION_DIR/compose.files"

PROFILE_ARGS=""
PROFILE_LIST="$OUT_DIR/profiles.txt"
: > "$PROFILE_LIST"
while IFS= read -r profile || [ -n "$profile" ]; do
  case "$profile" in
    ""|\#*) continue ;;
  esac
  PROFILE_ARGS="$PROFILE_ARGS --profile $profile"
  echo "$profile" >> "$PROFILE_LIST"
done < "$OPTION_DIR/profiles.txt"

echo "Option: $OPTION"
echo "Environment layers:"
cat "$ENV_LIST"
echo "Compose files:"
cat "$FILE_LIST"
echo "Profiles:"
cat "$PROFILE_LIST"

# shellcheck disable=SC2086
docker compose $ENV_ARGS $FILE_ARGS $PROFILE_ARGS config --quiet
# shellcheck disable=SC2086
docker compose $ENV_ARGS $FILE_ARGS $PROFILE_ARGS config > "$OUT_DIR/compose.resolved.yaml"

ENV_OUT="$OUT_DIR/environment.resolved.txt"
: > "$ENV_OUT"
for env_file in "$ROOT/env/defaults.env" "$ROOT/env/workspace.env" "$ROOT/env/modes/$MODE.env" "$OPTION_DIR/option.env" "$OPTION_DIR/.env" "$ROOT/env/local.user.override.env"; do
  [ -f "$env_file" ] || continue
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      ""|\#*) continue ;;
    esac
    case "$key" in
      *PASSWORD*|*SECRET*|*TOKEN*|*PRIVATE*|*PEM*|*API_KEY*|*HMAC_KEY*|*SIGNING_KEY*)
        [ -n "${value:-}" ] && value='***'
        ;;
    esac
    printf '%s=%s\n' "$key" "${value:-}" >> "$ENV_OUT"
  done < "$env_file"
done

echo "Rendered Compose config: $OUT_DIR/compose.resolved.yaml"
echo "Rendered environment summary: $ENV_OUT"
