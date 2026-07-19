#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CR=$(printf '\r')
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
  value=${value%"$CR"}
  case "$key" in
    OPTION_KIND) OPTION_KIND=$value ;;
    LOCAL_AI_PREPARE_MODEL) LOCAL_AI_PREPARE_MODEL=$value ;;
    LOCAL_AI_BASE_MODEL) LOCAL_AI_BASE_MODEL=$value ;;
    LOCAL_AI_MODEL) LOCAL_AI_MODEL=$value ;;
  esac
done < "$OPTION_DIR/option.env"

"$ROOT/scripts/config.sh" "$OPTION"

GENERATED_DIR="$ROOT/.generated/$OPTION"
if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "Dry run complete. Safe diagnostics: $GENERATED_DIR"
  exit 0
fi

RUNTIME_ENV_ARGS=""
while IFS= read -r rel || [ -n "$rel" ]; do
  rel=${rel%"$CR"}
  [ -n "$rel" ] || continue
  RUNTIME_ENV_ARGS="$RUNTIME_ENV_ARGS --env-file $ROOT/$rel"
done < "$ROOT/.generated/$OPTION/environment.layers.txt"
RUNTIME_FILE_ARGS=""
while IFS= read -r rel || [ -n "$rel" ]; do
  rel=${rel%"$CR"}
  [ -n "$rel" ] || continue
  RUNTIME_FILE_ARGS="$RUNTIME_FILE_ARGS -f $ROOT/$rel"
done < "$ROOT/.generated/$OPTION/compose.files.txt"
RUNTIME_PROFILE_ARGS=""
while IFS= read -r profile || [ -n "$profile" ]; do
  profile=${profile%"$CR"}
  [ -n "$profile" ] || continue
  RUNTIME_PROFILE_ARGS="$RUNTIME_PROFILE_ARGS --profile $profile"
done < "$ROOT/.generated/$OPTION/profiles.txt"

compose_runtime() {
  # shellcheck disable=SC2086
  docker compose $RUNTIME_ENV_ARGS $RUNTIME_FILE_ARGS $RUNTIME_PROFILE_ARGS "$@"
}

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
  echo
  echo "=== [start] Startup failed; targeted diagnostics follow ==="
  echo "Compose services:"
  compose_runtime ps || true
  for service in api-gateway auth-service account-service config-server discovery-server valkey postgres; do
    echo
    echo "--- $service status ---"
    compose_runtime ps "$service" || true
    echo "--- $service logs (tail 160) ---"
    compose_runtime logs --tail=160 "$service" || true
  done
  gateway_container=$(compose_runtime ps -q api-gateway 2>/dev/null || true)
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

if compose_runtime config --services | grep -qx postgres; then
  echo "=== [start] Starting Postgres before database clients ==="
  set +e
  compose_runtime up -d --build --wait --wait-timeout "$START_WAIT_TIMEOUT_SECONDS" postgres
  postgres_exit=$?
  set -e
  if [ "$postgres_exit" -ne 0 ]; then
    dump_start_failure
    exit "$postgres_exit"
  fi

  echo "=== [start] Reconciling Postgres roles with current environment ==="
  compose_runtime exec -T postgres /bin/bash /docker-entrypoint-initdb.d/00_init.sh
fi

echo "=== [start] Starting $OPTION from the validated semantic Compose files ==="
set +e
compose_runtime up -d --build --wait --wait-timeout "$START_WAIT_TIMEOUT_SECONDS"
start_exit=$?
set -e
if [ "$start_exit" -ne 0 ]; then
  dump_start_failure
  exit "$start_exit"
fi

if [ "$LOCAL_AI_PREPARE_MODEL" = "true" ]; then
  echo "=== [start] Preparing Ollama model $LOCAL_AI_BASE_MODEL and alias $LOCAL_AI_MODEL ==="
  compose_runtime exec ollama ollama pull "$LOCAL_AI_BASE_MODEL"
  compose_runtime exec ollama ollama create "$LOCAL_AI_MODEL" -f /Modelfile.planner
fi

echo "=== [start] $OPTION is up ==="
