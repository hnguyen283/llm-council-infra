#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CR=$(printf '\r')
failed=0

fail() {
  echo "ERROR: $*" >&2
  failed=1
}

value_from_option() {
  key=$1
  file=$2
  awk -F= -v k="$key" '$1 == k {value=substr($0, length(k) + 2); sub(/\r$/, "", value); print value}' "$file" | tail -n 1
}

for env_file in "$ROOT/env/defaults.env" "$ROOT/env/modes/http.env" "$ROOT/env/modes/https.env" "$ROOT"/options/*/option.env; do
  [ -f "$env_file" ] || continue
  while IFS='=' read -r key value || [ -n "$key" ]; do
    value=${value%"$CR"}
    case "$key" in
      ""|\#*) continue ;;
      *_FILE|*_DIR) continue ;;
    esac
    case "$key" in
      *PASSWORD*|*SECRET*|*TOKEN*|*PRIVATE*|*PEM*|*API_KEY*|*HMAC_KEY*|*SIGNING_KEY*)
        if [ -n "${value:-}" ]; then
          fail "tracked secret-like value is non-empty in $env_file: $key"
        fi
        ;;
    esac
  done < "$env_file"
done

for option_dir in "$ROOT"/options/*; do
  [ -d "$option_dir" ] || continue
  option_file="$option_dir/option.env"
  [ -f "$option_file" ] || continue
  option=$(basename "$option_dir")

  duplicate_keys=$(awk -F= '!/^($|#)/ {count[$1]++} END {for (key in count) if (count[key] > 1) print key}' "$option_file")
  if [ -n "$duplicate_keys" ]; then
    fail "$option has duplicate option.env keys: $(printf '%s' "$duplicate_keys" | tr '\n' ' ')"
  fi

  declared_name=$(value_from_option OPTION_NAME "$option_file")
  [ "$declared_name" = "$option" ] || fail "$option OPTION_NAME must match its directory name"

  [ -f "$option_dir/compose.files" ] || continue
  kind=$(value_from_option OPTION_KIND "$option_file")
  case "$kind" in
    vps-deploy|vps-hybrid) continue ;;
  esac

  scheme=$(value_from_option PUBLIC_SCHEME "$option_file")
  host=$(value_from_option PUBLIC_HOST "$option_file")
  port=$(value_from_option PUBLIC_PORT "$option_file")
  origin=$(value_from_option PUBLIC_ORIGIN "$option_file")
  case "$scheme" in
    http|https) ;;
    *) fail "$option PUBLIC_SCHEME must be http or https" ;;
  esac
  [ -n "$host" ] || fail "$option PUBLIC_HOST is required"
  case "$port" in
    ''|*[!0-9]*) fail "$option PUBLIC_PORT must be numeric" ;;
  esac
  expected_origin="$scheme://$host:$port"
  if [ "$scheme" = "https" ] && [ "$port" = "443" ]; then
    expected_origin="https://$host"
  elif [ "$scheme" = "http" ] && [ "$port" = "80" ]; then
    expected_origin="http://$host"
  fi
  [ "$origin" = "$expected_origin" ] || fail "$option PUBLIC_ORIGIN must derive from scheme, host, and port"

  ui_runtime=$(value_from_option UI_RUNTIME_MODE "$option_file")
  production_like=$(value_from_option PRODUCTION_LIKE_UI "$option_file")
  case "$option" in
    prod-*-local*)
      [ "$ui_runtime" = "nginx-static" ] || fail "$option must use nginx-static UI runtime"
      [ "$production_like" = "true" ] || fail "$option must declare PRODUCTION_LIKE_UI=true"
      grep -q '^compose/compose.ui-nginx.yaml$' "$option_dir/compose.files" || fail "$option must include compose.ui-nginx.yaml"
      ;;
    dev-full-*)
      [ "$ui_runtime" = "angular-dev-server" ] || fail "$option must use angular-dev-server"
      [ "$production_like" = "false" ] || fail "$option must declare PRODUCTION_LIKE_UI=false"
      grep -q '^compose/compose.ui-dev.yaml$' "$option_dir/compose.files" || fail "$option must include compose.ui-dev.yaml"
      ;;
  esac

  if [ "$scheme" = "https" ]; then
    secure_cookie=$(value_from_option AUTH_COOKIE_SECURE "$option_file")
    [ "$secure_cookie" = "true" ] || fail "$option must enable secure auth cookies"
    tls_termination=$(value_from_option TLS_TERMINATION "$option_file")
    if [ "$tls_termination" != "cloudflare" ]; then
      local_tls_trust_required=$(value_from_option LOCAL_TLS_TRUST_REQUIRED "$option_file")
      case "$local_tls_trust_required" in
        true|false) ;;
        *) fail "$option LOCAL_TLS_TRUST_REQUIRED must be true or false" ;;
      esac
    fi
  fi

  case "$option" in
    *-tunnel)
      grep -q '^compose/compose.tunnel.yaml$' "$option_dir/compose.files" || fail "$option must include compose.tunnel.yaml"
      grep -q '^compose/compose.edge-http.yaml$' "$option_dir/compose.files" || fail "$option must use the internal HTTP edge behind Cloudflare TLS"
      grep -q '^tunnel$' "$option_dir/profiles.txt" || fail "$option must enable the tunnel profile"
      [ "$(value_from_option TLS_TERMINATION "$option_file")" = "cloudflare" ] || fail "$option must declare TLS_TERMINATION=cloudflare"
      [ "$(value_from_option EDGE_CONTAINER_PORT "$option_file")" = "8080" ] || fail "$option tunnel origin must target portal-edge HTTP port 8080"
      [ "$(value_from_option EDGE_FORWARDED_PROTO "$option_file")" = "https" ] || fail "$option must forward the public HTTPS scheme"
      [ "$(value_from_option EDGE_FORWARDED_PORT "$option_file")" = "443" ] || fail "$option must forward public port 443"
      [ "$(value_from_option LOCAL_SERVICE_MAPPING "$option_file")" = "http://localhost:8080" ] || fail "$option must match the remotely managed Cloudflare origin"
      ;;
  esac
done

[ "$failed" -eq 0 ]
echo "Environment and option contract checks passed."
