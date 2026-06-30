#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPTION=${1:-prod-full-local-http}
DRY_RUN=${2:-}
OPTION_DIR="$ROOT/options/$OPTION"
START_WAIT_TIMEOUT_SECONDS=${START_WAIT_TIMEOUT_SECONDS:-600}

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
  server_api=
  pinned_api=
  for candidate in 1.53 1.52 1.51 1.50 1.49 1.48 1.47 1.46 1.45 1.44 1.43 1.42 1.41; do
    export DOCKER_API_VERSION=$candidate
    server_api=$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || true)
    if [ -n "$server_api" ]; then
      pinned_api=$candidate
      break
    fi
  done
  if [ -n "$pinned_api" ]; then
    export DOCKER_API_VERSION=$pinned_api
    echo "Docker Engine API version pinned to $pinned_api (server reports $server_api)"
    return 0
  fi
  if [ -n "$original" ]; then
    export DOCKER_API_VERSION=$original
  fi
  echo "ERROR: Docker Engine is not reachable or API negotiation failed." >&2
  echo "Try restarting Docker Desktop, then run: DOCKER_API_VERSION=1.51 docker version" >&2
  docker version
  return 1
}

pin_docker_api_version

dump_start_failure() {
  compose_config=$1
  echo
  echo "=== [start] Startup failed; targeted diagnostics follow ==="
  echo "Compose services:"
  docker compose -f "$compose_config" ps || true
  for service in api-gateway auth-service account-service config-server discovery-server valkey postgres; do
    echo
    echo "--- $service status ---"
    docker compose -f "$compose_config" ps "$service" || true
    echo "--- $service logs (tail 160) ---"
    docker compose -f "$compose_config" logs --tail=160 "$service" || true
  done
  gateway_container=$(docker compose -f "$compose_config" ps -q api-gateway 2>/dev/null || true)
  if [ -n "$gateway_container" ]; then
    echo
    echo "--- api-gateway Docker health state ---"
    docker inspect "$gateway_container" --format '{{json .State.Health}}' || true
  fi
}

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
set +e
docker compose -f "$GENERATED" up -d --build --wait --wait-timeout "$START_WAIT_TIMEOUT_SECONDS"
start_exit=$?
set -e
if [ "$start_exit" -ne 0 ]; then
  dump_start_failure "$GENERATED"
  exit "$start_exit"
fi

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
