#!/usr/bin/env bash
# ============================================================================
# prod-lite.sh -- Remote VPS deployment entrypoint for the experimental stack.
#
# This script is copied to the VPS by deploy-vps.cmd and executed only after
# deploy-vps.cmd has injected environment variables into the SSH session.
#
# SECURITY RULE:
#   Never persist .env or secret files on the VPS. This script must receive
#   sensitive values only as process environment variables from the caller.
# ============================================================================

set -euo pipefail
set +x

REMOTE_DIR="${REMOTE_DIR:-/opt/llm-council}"
WAIT_SECONDS="${WAIT_SECONDS:-300}"
PUBLIC_WEB_ROOT="${PUBLIC_WEB_ROOT:-/var/www/welllifeapp/ui}"
ADMIN_WEB_ROOT="${ADMIN_WEB_ROOT:-/var/www/welllifeapp/admin-ui}"
LOG_DIR_HOST="${LOG_DIR_HOST:-/var/log/llm-council}"

dc() {
  COMPOSE_DISABLE_ENV_FILE=1 docker compose --env-file /dev/null "$@"
}

require_env() {
  local missing=()
  for key in "$@"; do
    if [[ -z "${!key:-}" ]]; then
      missing+=("$key")
    fi
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    printf 'ERROR: missing required environment variable(s): %s\n' "${missing[*]}" >&2
    exit 1
  fi
}

ensure_network() {
  local name="$1"
  docker network inspect "$name" >/dev/null 2>&1 || docker network create -d bridge "$name" >/dev/null
}

copy_ui_dist() {
  local src="$1"
  local dst="$2"
  local label="$3"

  if [[ ! -d "$src" ]]; then
    printf 'WARNING: %s build output not found at %s; skipping static UI refresh.\n' "$label" "$src"
    return 0
  fi
  if [[ -z "$dst" || "$dst" == "/" ]]; then
    printf 'ERROR: invalid %s web root: %s\n' "$label" "$dst" >&2
    exit 1
  fi

  mkdir -p "$dst"
  find "$dst" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  cp -a "$src"/. "$dst"/
  printf '%s static files refreshed at %s\n' "$label" "$dst"
}

prepare_log_dirs() {
  mkdir -p "$LOG_DIR_HOST"/platform "$LOG_DIR_HOST"/core "$LOG_DIR_HOST"/graphrag
  chmod 755 "$LOG_DIR_HOST"

  # Containers run as non-root users with service-specific UIDs. Keep the log
  # subdirectories writable while the VPS experiment is single-tenant.
  chmod 1777 "$LOG_DIR_HOST"/platform "$LOG_DIR_HOST"/core "$LOG_DIR_HOST"/graphrag
  find "$LOG_DIR_HOST" -type f -name '*.log' -exec chmod 0666 {} + 2>/dev/null || true
}

printf '\n=== [prod-lite.sh] Validating required runtime environment ===\n'
require_env \
  POSTGRES_USER \
  POSTGRES_PASSWORD \
  POSTGRES_DB \
  ACCOUNT_DB_USER \
  ACCOUNT_DB_PASSWORD \
  PROMPT_DB_USER \
  PROMPT_DB_PASSWORD \
  VALKEY_PASSWORD \
  AUTH_JWT_SIGNING_KID \
  AUTH_JWT_PRIVATE_KEY_PEM \
  AUTH_JWT_PUBLIC_KEYS_PEM \
  GATEWAY_INTERNAL_KID \
  GATEWAY_INTERNAL_PRIVATE_KEY_PEM \
  GATEWAY_INTERNAL_PUBLIC_KEYS_PEM \
  ACCOUNT_INTERNAL_SERVICE_TOKEN \
  TENANT_NAMESPACE_HMAC_KEY \
  GEMINI_API_KEY \
  OPENAI_API_KEY \
  GRAPHRAG_DB_PASSWORD \
  LOG_DIR_HOST

cd "$REMOTE_DIR"
prepare_log_dirs

printf '\n=== [prod-lite.sh] Refusing persisted env files ===\n'
if find "$REMOTE_DIR" \( \
    -name '.env' -o \
    -name '.env.*' -o \
    -name '.env.local' -o \
    -name 'prod-lite.env' -o \
    -name 'hostInfo.txt' -o \
    -name '*.pem' -o \
    -name '*.key' -o \
    -name '*.p12' -o \
    -type d -name 'ssl' \
  \) | grep -q .; then
  printf 'ERROR: forbidden sensitive files exist under %s. Remove them before deploying.\n' "$REMOTE_DIR" >&2
  exit 1
fi

DATA_FILES=(-f projects/data/docker-compose.yml -f projects/data/overlays/postgres-external.yml -f projects/data/overlays/vps-operational.yml)
MESSAGING_FILES=(-f projects/messaging/docker-compose.yml -f projects/messaging/overlays/prod-laptop-tunnel.yml)
PLAT_FILES=(-f projects/platform/docker-compose.yml -f projects/platform/overlays/prod.yml -f projects/platform/overlays/log-files.yml)
CORE_FILES=(-f projects/core/docker-compose.yml -f projects/core/overlays/prod.yml -f projects/core/overlays/prod-lite.yml -f projects/core/overlays/log-files.yml)
GRAPHRAG_FILES=(-f projects/graphrag/docker-compose.yml -f projects/graphrag/overlays/log-files.yml)

export DB_URL="jdbc:postgresql://postgres:5432/operational_db"

printf '\n=== [prod-lite.sh] Ensuring external Docker networks ===\n'
ensure_network llm-council-data
ensure_network llm-council-messaging
ensure_network llm-council-observability
ensure_network llm-council-platform
ensure_network llm-council-app
ensure_network llm-council-ai-runtime

printf '\n=== [prod-lite.sh] Refreshing static UI files when dist is present ===\n'
copy_ui_dist "ui-source/llm-council-ui/dist/ai-orchestrator-ui/browser" "$PUBLIC_WEB_ROOT" "portal UI"
copy_ui_dist "ui-source/llm-council-admin-ui/dist/llm-council-admin-ui/browser" "$ADMIN_WEB_ROOT" "admin UI"

printf '\n=== [prod-lite.sh] Stopping previous app containers ===\n'
dc "${CORE_FILES[@]}" down --remove-orphans || true
dc "${GRAPHRAG_FILES[@]}" down --remove-orphans || true
dc "${PLAT_FILES[@]}" down --remove-orphans || true
dc "${MESSAGING_FILES[@]}" down --remove-orphans || true
dc "${DATA_FILES[@]}" down --remove-orphans || true

printf '\n=== [prod-lite.sh] Building images from transferred JAR artifacts ===\n'
dc "${DATA_FILES[@]}" build postgres
dc "${PLAT_FILES[@]}" build --no-cache config-server discovery-server
dc "${CORE_FILES[@]}" build --no-cache \
  api-gateway \
  auth-service \
  account-service \
  orchestrator-service \
  prompt-service \
  gemini-service \
  gpt-service

if [[ "${GRAPHRAG_ENABLED:-false}" == "true" ]]; then
  printf '\n=== [prod-lite.sh] Building GraphRAG images ===\n'
  dc "${GRAPHRAG_FILES[@]}" build --no-cache graphrag-retrieval-service graphrag-indexing-worker
fi

printf '\n=== [prod-lite.sh] Validating Compose config ===\n'
dc "${DATA_FILES[@]}" config --quiet
dc "${MESSAGING_FILES[@]}" config --quiet
dc "${PLAT_FILES[@]}" config --quiet
dc "${CORE_FILES[@]}" config --quiet
if [[ "${GRAPHRAG_ENABLED:-false}" == "true" ]]; then
  dc "${GRAPHRAG_FILES[@]}" config --quiet
fi

printf '\n=== [prod-lite.sh] Starting data tier ===\n'
dc "${DATA_FILES[@]}" up -d --wait --wait-timeout "$WAIT_SECONDS" postgres valkey
dc "${DATA_FILES[@]}" exec -T postgres /bin/bash /docker-entrypoint-initdb.d/00_init.sh

printf '\n=== [prod-lite.sh] Starting messaging tier ===\n'
dc "${MESSAGING_FILES[@]}" up -d --wait --wait-timeout "$WAIT_SECONDS" kafka

printf '\n=== [prod-lite.sh] Starting platform tier ===\n'
dc "${PLAT_FILES[@]}" up -d --wait --wait-timeout "$WAIT_SECONDS" config-server discovery-server

if [[ "${GRAPHRAG_ENABLED:-false}" == "true" ]]; then
  printf '\n=== [prod-lite.sh] Starting GraphRAG tier ===\n'
  dc "${GRAPHRAG_FILES[@]}" up -d --wait --wait-timeout "$WAIT_SECONDS" graphrag-retrieval-service graphrag-indexing-worker
fi

printf '\n=== [prod-lite.sh] Starting core identity and gateway ===\n'
dc "${CORE_FILES[@]}" up -d --wait --wait-timeout "$WAIT_SECONDS" account-service auth-service api-gateway

printf '\n=== [prod-lite.sh] Starting fallback AI workers ===\n'
dc "${CORE_FILES[@]}" up -d --wait --wait-timeout "$WAIT_SECONDS" prompt-service gemini-service gpt-service

printf '\n=== [prod-lite.sh] Starting orchestrator ===\n'
dc "${CORE_FILES[@]}" up -d --wait --wait-timeout "$WAIT_SECONDS" orchestrator-service

printf '\n=== [prod-lite.sh] Final core service status ===\n'
dc "${CORE_FILES[@]}" ps

printf '\n=== [prod-lite.sh] Deployment complete ===\n'
