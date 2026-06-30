#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPTION=${1:-prod-full-local-http}
DRY_RUN=${2:-}
OPTION_DIR="$ROOT/options/$OPTION"

if [ ! -f "$OPTION_DIR/compose.files" ]; then
  echo "ERROR: \"$OPTION\" is not a local Compose start option." >&2
  echo "See $OPTION_DIR/README.md for the correct command." >&2
  exit 1
fi

OPTION_KIND=compose-stack
LOCAL_AI_PREPARE_MODEL=false
LOCAL_AI_BASE_MODEL=deepseek-r1:7b
LOCAL_AI_MODEL=planner
while IFS='=' read -r key value || [ -n "$key" ]; do
  case "$key" in
    OPTION_KIND) OPTION_KIND=$value ;;
    LOCAL_AI_PREPARE_MODEL) LOCAL_AI_PREPARE_MODEL=$value ;;
    LOCAL_AI_BASE_MODEL) LOCAL_AI_BASE_MODEL=$value ;;
    LOCAL_AI_MODEL) LOCAL_AI_MODEL=$value ;;
  esac
done < "$OPTION_DIR/option.env"

"$ROOT/scripts/config.sh" "$OPTION"

GENERATED="$ROOT/.generated/$OPTION/compose.resolved.yaml"
if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "Dry run complete. Rendered config: $GENERATED"
  exit 0
fi

pin_docker_api_version() {
  original=${DOCKER_API_VERSION:-}
  unset DOCKER_API_VERSION
  server_api=$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || true)
  if [ -n "$server_api" ]; then
    export DOCKER_API_VERSION=$server_api
    echo "Docker Engine API version: $DOCKER_API_VERSION"
    return 0
  fi
  if [ -n "$original" ]; then
    export DOCKER_API_VERSION=$original
  fi
  echo "ERROR: Docker Engine is not reachable or API negotiation failed." >&2
  echo "Try restarting Docker Desktop, then run: docker version" >&2
  docker version
  return 1
}

pin_docker_api_version

ensure_network() {
  name=$1
  if docker network inspect "$name" >/dev/null 2>&1; then
    echo "Network $name already exists."
  else
    docker network create -d bridge "$name" >/dev/null
    echo "Created network $name."
  fi
}

ensure_network llm-council-data
ensure_network llm-council-messaging
ensure_network llm-council-observability
ensure_network llm-council-platform
ensure_network llm-council-app
ensure_network llm-council-ai-runtime

if [ "$OPTION_KIND" = "local-ai-runtime" ]; then
  echo "=== [start] Skipping Spring package for local AI runtime option ==="
else
  echo "=== [start] Packaging Spring service JARs ==="
  (cd "$ROOT/../llm-council" && mvn -DskipTests package)
fi

echo "=== [start] Starting $OPTION from rendered Compose config ==="
docker compose -f "$GENERATED" up -d --build --wait --wait-timeout 300

if docker compose -f "$GENERATED" ps postgres >/dev/null 2>&1; then
  echo "=== [start] Applying idempotent Postgres bootstrap ==="
  docker compose -f "$GENERATED" exec -T postgres /bin/bash /docker-entrypoint-initdb.d/00_init.sh
fi

if [ "$OPTION_KIND" = "local-ai-runtime" ] && [ "$LOCAL_AI_PREPARE_MODEL" = "true" ]; then
  echo "=== [start] Preparing Ollama model $LOCAL_AI_BASE_MODEL and alias $LOCAL_AI_MODEL ==="
  docker compose -f "$GENERATED" exec ollama ollama pull "$LOCAL_AI_BASE_MODEL"
  docker compose -f "$GENERATED" exec ollama ollama create "$LOCAL_AI_MODEL" -f /Modelfile.planner
fi

echo "=== [start] $OPTION is up ==="
