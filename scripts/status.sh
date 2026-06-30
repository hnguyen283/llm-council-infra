#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPTION=${1:-prod-full-local-http}
"$ROOT/scripts/config.sh" "$OPTION"
docker compose -f "$ROOT/.generated/$OPTION/compose.resolved.yaml" ps
