#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CR=$(printf '\r')
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
ENV_LAYER_FILES=""
ENV_LIST="$OUT_DIR/environment.layers.txt"
: > "$ENV_LIST"
add_env() {
  rel=$1
  abs="$ROOT/$rel"
  if [ -f "$abs" ]; then
    ENV_ARGS="$ENV_ARGS --env-file $abs"
    ENV_LAYER_FILES="$ENV_LAYER_FILES $abs"
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
  line=${line%"$CR"}
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
  profile=${profile%"$CR"}
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
LEGACY_MODEL="$OUT_DIR/compose.resolved.yaml"
if [ -f "$LEGACY_MODEL" ]; then
  rm -f -- "$LEGACY_MODEL"
fi
# Persist only metadata that cannot contain interpolated secret values. Runtime
# commands reassemble the validated Compose files from the recorded lists.
# shellcheck disable=SC2086
docker compose $ENV_ARGS $FILE_ARGS $PROFILE_ARGS config --services > "$OUT_DIR/compose.services.txt"

ENV_OUT="$OUT_DIR/environment.resolved.txt"
# Resolve only declared option-layer keys. Later files and process environment
# values win, matching Compose interpolation precedence, while secret-like
# values are masked before anything reaches disk.
# shellcheck disable=SC2086
awk '
  /^[[:space:]]*($|#)/ { next }
  {
    separator = index($0, "=")
    if (separator <= 1) next
    key = substr($0, 1, separator - 1)
    value = substr($0, separator + 1)
    sub(/\r$/, "", value)
    if (!(key in seen)) {
      order[++count] = key
      seen[key] = 1
    }
    values[key] = value
  }
  END {
    for (i = 1; i <= count; i++) {
      key = order[i]
      value = (key in ENVIRON) ? ENVIRON[key] : values[key]
      upper = toupper(key)
      if (upper !~ /(_FILE|_DIR)$/ &&
          upper ~ /(PASSWORD|SECRET|TOKEN|PRIVATE|PEM|API_KEY|HMAC_KEY|SIGNING_KEY)/ &&
          value != "") {
        value = "***"
      }
      print key "=" value
    }
  }
' $ENV_LAYER_FILES > "$ENV_OUT"

echo "Rendered service summary: $OUT_DIR/compose.services.txt"
echo "Rendered environment summary: $ENV_OUT"
