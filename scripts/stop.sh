#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CR=$(printf '\r')
OPTION=${1:-prod-full-local-http}
"$ROOT/scripts/config.sh" "$OPTION"
ENV_ARGS=""
while IFS= read -r rel || [ -n "$rel" ]; do rel=${rel%"$CR"}; [ -n "$rel" ] && ENV_ARGS="$ENV_ARGS --env-file $ROOT/$rel"; done < "$ROOT/.generated/$OPTION/environment.layers.txt"
FILE_ARGS=""
while IFS= read -r rel || [ -n "$rel" ]; do rel=${rel%"$CR"}; [ -n "$rel" ] && FILE_ARGS="$FILE_ARGS -f $ROOT/$rel"; done < "$ROOT/.generated/$OPTION/compose.files.txt"
PROFILE_ARGS=""
while IFS= read -r profile || [ -n "$profile" ]; do profile=${profile%"$CR"}; [ -n "$profile" ] && PROFILE_ARGS="$PROFILE_ARGS --profile $profile"; done < "$ROOT/.generated/$OPTION/profiles.txt"
# shellcheck disable=SC2086
docker compose $ENV_ARGS $FILE_ARGS $PROFILE_ARGS down --remove-orphans
