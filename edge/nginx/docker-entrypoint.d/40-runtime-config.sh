#!/bin/sh
set -eu

cat > /usr/share/nginx/html/runtime-config.json <<EOF
{
  "apiBasePath": "${API_BASE_PATH:-/api}",
  "authBasePath": "${AUTH_BASE_PATH:-/auth}",
  "publicOrigin": "${PUBLIC_ORIGIN:-http://localhost:8080}",
  "releaseLabel": "${RELEASE_LABEL:-local}"
}
EOF
