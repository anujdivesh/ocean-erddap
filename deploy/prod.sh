#!/usr/bin/env bash
# Production deployment of ERDDAP + Push API with Docker, served over HTTPS.
#
#   deploy/prod.sh up        validate .env, pull/build images, (re)create and start everything
#   deploy/prod.sh down      stop and remove the containers (data, config, certificates kept)
#   deploy/prod.sh stop      stop the containers (keep them; resume with "start")
#   deploy/prod.sh start     start previously stopped containers
#   deploy/prod.sh restart   restart the containers
#   deploy/prod.sh status    show container state and health checks
#   deploy/prod.sh logs [erddap|api|proxy]   follow logs (default: erddap)
#
# Settings: .env in the repository root (override with ENV_FILE=/path/to/.env).
# HTTPS (TLS_MODE in .env): auto = Let's Encrypt via a Caddy container,
# certfiles = your certificate via Caddy, external = your own nginx in front,
# internal = self-signed (testing).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ENV_FILE="${ENV_FILE:-${ROOT}/.env}"

die() { echo "ERROR: $*" >&2; exit 1; }
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE (create it: cp .env.template .env)"
command -v docker >/dev/null || die "docker is not installed"

# Use docker directly if this user may, otherwise via sudo (user not in the docker group).
DOCKER_BIN="$(command -v docker)"
if "$DOCKER_BIN" info >/dev/null 2>&1; then
  DOCKER=("$DOCKER_BIN")
elif [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null; then
  echo "Note: $(id -un) has no direct Docker access; using sudo." >&2
  sudo "$DOCKER_BIN" info >/dev/null || die "cannot reach Docker even with sudo (is the Docker service running?)"
  DOCKER=(sudo "$DOCKER_BIN")
else
  die "cannot reach Docker (is the Docker service running?)"
fi
docker() { "${DOCKER[@]}" "$@"; }

# Read .env literally (no shell evaluation, so spaces, parens and | are safe).
while IFS= read -r line || [ -n "$line" ]; do
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || die "bad line in .env: $line"
  printf -v "${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
done < "$ENV_FILE"

IMAGE="${ERDDAP_IMAGE:-erddap/erddap:v2.30.0}"
NAME="${CONTAINER_NAME:-erddap}"
BIND="${ERDDAP_BIND_ADDRESS:-127.0.0.1}"
PORT="${ERDDAP_HTTP_PORT:-8080}"
API_ENABLED="${PUSH_API_ENABLED:-true}"
API_NAME="${NAME}_push_api"
API_IMAGE="erddap-push-api"
API_PORT="${PUSH_API_PORT:-8000}"
PROXY_NAME="${NAME}_proxy"
PROXY_IMAGE="caddy:2.8.4"
NET="${NAME}_net"
DOMAIN="${DOMAIN:-}"
TLS_MODE="${TLS_MODE:-auto}"
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"

# Public URL that ERDDAP puts in every link (baseUrl). Derived from DOMAIN.
if [ "$TLS_MODE" != "external" ] && [ "$HTTPS_PORT" != "443" ]; then
  PUBLIC_URL="https://${DOMAIN}:${HTTPS_PORT}"
else
  PUBLIC_URL="https://${DOMAIN}"
fi

containers() {
  echo "$NAME"
  [ "$API_ENABLED" = "true" ] && echo "$API_NAME"
  [ "$TLS_MODE" != "external" ] && echo "$PROXY_NAME"
  return 0
}
exists() { docker container inspect "$1" >/dev/null 2>&1; }

validate() {
  grep -q '^[^#]*CHANGE_ME' "$ENV_FILE" && die ".env still contains CHANGE_ME values:
$(grep -n '^[^#]*CHANGE_ME' "$ENV_FILE")"
  grep -Eq '^[A-Za-z_]+=["'\'']' "$ENV_FILE" && die ".env values must not be quoted"
  [ -n "$DOMAIN" ] || die "DOMAIN is empty"
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "DOMAIN must be a bare host name like erddap.spc.int (no https://, no path)"
  case "$TLS_MODE" in
    auto)
      [[ "${ACME_EMAIL:-}" == *@* ]] || die "TLS_MODE=auto needs ACME_EMAIL"
      [[ "$DOMAIN" == localhost || "$DOMAIN" != *.* ]] && die "TLS_MODE=auto needs a public domain (Let's Encrypt)"
      ;;
    certfiles)
      [ -r "${TLS_CERT_FILE:-}" ] || die "TLS_CERT_FILE not readable: ${TLS_CERT_FILE:-<empty>}"
      [ -r "${TLS_KEY_FILE:-}" ] || die "TLS_KEY_FILE not readable: ${TLS_KEY_FILE:-<empty>}"
      ;;
    external|internal) ;;
    *) die "TLS_MODE must be auto, certfiles, external or internal (got: $TLS_MODE)" ;;
  esac
  [ "${#ERDDAP_flagKeyKey}" -ge 20 ] || die "ERDDAP_flagKeyKey is too short (use: openssl rand -hex 32)"
  [[ "$ERDDAP_flagKeyKey" == *change-this* ]] && die "ERDDAP_flagKeyKey is still the default"
  for f in erddap/content/setup.xml erddap/content/datasets.xml erddap/conf/robots.txt deploy/caddy/Caddyfile; do
    [ -f "$f" ] || die "missing $f"
  done
  if [ "$API_ENABLED" = "true" ] && ! grep -q '<user ' erddap/content/datasets.xml; then
    echo "WARNING: no <user> in datasets.xml: nobody can log in to the Push API" >&2
  fi
  return 0
}

https_code() {
  # Request the public URL but connect to this machine (works before DNS is live).
  curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" "https://${DOMAIN}:${HTTPS_PORT}$1" || true
}

wait_healthy() {
  echo "Waiting for ERDDAP (first start can take a few minutes)..."
  for _ in $(seq 1 90); do
    if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/erddap/index.html" 2>/dev/null; then
      echo "OK: ERDDAP is up."
      if [ "$TLS_MODE" != "external" ]; then
        local code; code="$(https_code /erddap/index.html)"
        if [ "$code" = 200 ]; then
          echo "OK: HTTPS is serving ${PUBLIC_URL}/erddap"
        else
          echo "WARNING: HTTPS check returned '$code'. For TLS_MODE=auto the certificate is issued on" >&2
          echo "         first use and needs DNS + ports 80/443 reachable. Check: $0 logs proxy" >&2
        fi
      fi
      echo "    ERDDAP:   ${PUBLIC_URL}/erddap"
      [ "$API_ENABLED" = "true" ] && echo "    Push API: ${PUBLIC_URL}/api"
      return 0
    fi
    sleep 5
  done
  echo "WARNING: ERDDAP not responding yet. Check: $0 logs" >&2
  return 1
}

cmd_up() {
  validate
  mkdir -p erddap/data/flag datasets
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
  docker pull -q "$IMAGE" >/dev/null
  [ "$API_ENABLED" = "true" ] && docker build -q -t "$API_IMAGE" "${ROOT}/api" >/dev/null
  [ "$TLS_MODE" != "external" ] && docker pull -q "$PROXY_IMAGE" >/dev/null

  docker rm -f "$NAME" "$API_NAME" "$PROXY_NAME" >/dev/null 2>&1 || true

  # erddap/conf/config.sh is deliberately NOT mounted: .env is the only configuration.
  docker run -d \
    --name "$NAME" \
    --network "$NET" \
    --restart unless-stopped \
    --env-file "$ENV_FILE" \
    -e ERDDAP_baseUrl="$PUBLIC_URL" \
    -e ERDDAP_baseHttpsUrl="$PUBLIC_URL" \
    -p "${BIND}:${PORT}:8080" \
    --log-driver json-file --log-opt max-size=50m --log-opt max-file=5 \
    -v "${ROOT}/erddap/conf/robots.txt:/usr/local/tomcat/webapps/ROOT/robots.txt:ro" \
    -v "${ROOT}/erddap/content:/usr/local/tomcat/content/erddap" \
    -v "${ROOT}/erddap/data:/erddapData" \
    -v "${ROOT}/datasets:/datasets:ro" \
    "$IMAGE" >/dev/null
  echo "Started $NAME ($IMAGE)"

  if [ "$API_ENABLED" = "true" ]; then
    # Only the settings it needs are passed (not the whole .env with its secrets).
    docker run -d \
      --name "$API_NAME" \
      --network "$NET" \
      --restart unless-stopped \
      -p "${BIND}:${API_PORT}:8000" \
      -e PUSH_ADMIN_ROLES="${PUSH_ADMIN_ROLES:-spc}" \
      -e MAX_UPLOAD_MB="${PUSH_MAX_UPLOAD_MB:-500}" \
      -e CLIENT_IP_HEADER="${PUSH_CLIENT_IP_HEADER:-}" \
      -e PUBLIC_URL="${PUBLIC_URL}" \
      --log-driver json-file --log-opt max-size=20m --log-opt max-file=5 \
      -v "${ROOT}/erddap/content:/erddap_content:ro" \
      -v "${ROOT}/datasets:/datasets" \
      -v "${ROOT}/erddap/data/flag:/erddapData/flag" \
      "$API_IMAGE" >/dev/null
    echo "Started $API_NAME"
  fi

  if [ "$TLS_MODE" != "external" ]; then
    local tls cert_mounts=()
    case "$TLS_MODE" in
      auto) tls="$ACME_EMAIL" ;;
      internal) tls="internal" ;;
      certfiles)
        tls="/certs/cert.pem /certs/key.pem"
        cert_mounts=(-v "${TLS_CERT_FILE}:/certs/cert.pem:ro" -v "${TLS_KEY_FILE}:/certs/key.pem:ro")
        ;;
    esac
    # Certificates persist in the ${NAME}_caddy_data volume (survives down/up).
    docker run -d \
      --name "$PROXY_NAME" \
      --network "$NET" \
      --restart unless-stopped \
      -p "${HTTP_PORT}:80" -p "${HTTPS_PORT}:443" -p "${HTTPS_PORT}:443/udp" \
      -e DOMAIN="$DOMAIN" \
      -e CADDY_TLS="$tls" \
      -e ERDDAP_UPSTREAM="${NAME}:8080" \
      -e API_UPSTREAM="${API_NAME}:8000" \
      --log-driver json-file --log-opt max-size=20m --log-opt max-file=5 \
      -v "${ROOT}/deploy/caddy:/etc/caddy:ro" \
      -v "${NAME}_caddy_data:/data" \
      -v "${NAME}_caddy_config:/config" \
      ${cert_mounts[@]+"${cert_mounts[@]}"} \
      "$PROXY_IMAGE" >/dev/null
    echo "Started $PROXY_NAME (HTTPS: $TLS_MODE) on ports ${HTTP_PORT}/${HTTPS_PORT}"
  else
    echo "TLS_MODE=external: point your reverse proxy (NPM/nginx) at port ${PORT} for /erddap and ${API_PORT} for /api"
    if [ "$BIND" = "0.0.0.0" ]; then
      echo "NOTE: ports ${PORT}/${API_PORT} listen on all interfaces; firewall them so only the proxy can connect." >&2
    fi
  fi
  wait_healthy
}

cmd_down() {
  for c in "$NAME" "$API_NAME" "$PROXY_NAME"; do
    if exists "$c"; then docker rm -f "$c" >/dev/null && echo "Removed $c"; fi
  done
  docker network rm "$NET" >/dev/null 2>&1 || true
  return 0
}

cmd_stop() {
  for c in $(containers); do
    if exists "$c"; then docker stop "$c" >/dev/null && echo "Stopped $c"; else echo "$c: not present"; fi
  done
}

cmd_start() {
  for c in $(containers); do
    exists "$c" || die "$c does not exist; run: $0 up"
    docker start "$c" >/dev/null && echo "Started $c"
  done
  wait_healthy
}

cmd_restart() {
  for c in $(containers); do
    exists "$c" || die "$c does not exist; run: $0 up"
    docker restart "$c" >/dev/null && echo "Restarted $c"
  done
  wait_healthy
}

cmd_status() {
  for c in $(containers); do
    if exists "$c"; then
      docker inspect "$c" --format '{{.Name}}  state={{.State.Status}}  restarts={{.RestartCount}}  image={{.Config.Image}}' | sed 's#^/##'
    else
      echo "$c  not present"
    fi
  done
  printf 'ERDDAP  http://127.0.0.1:%s/erddap/index.html -> %s\n' "$PORT" \
    "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/erddap/index.html" || true)"
  if [ "$API_ENABLED" = "true" ]; then
    printf 'API     http://127.0.0.1:%s/api/health       -> %s\n' "$API_PORT" \
      "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${API_PORT}/api/health" || true)"
  fi
  if [ "$TLS_MODE" != "external" ]; then
    printf 'HTTPS   %s/erddap/index.html -> %s\n' "$PUBLIC_URL" "$(https_code /erddap/index.html)"
    [ "$API_ENABLED" = "true" ] && printf 'HTTPS   %s/api/health -> %s\n' "$PUBLIC_URL" "$(https_code /api/health)"
  fi
  return 0
}

cmd_logs() {
  case "${1:-erddap}" in
    erddap) exec "${DOCKER[@]}" logs -f --tail 200 "$NAME" ;;
    api)    exec "${DOCKER[@]}" logs -f --tail 200 "$API_NAME" ;;
    proxy)  exec "${DOCKER[@]}" logs -f --tail 200 "$PROXY_NAME" ;;
    *) die "usage: $0 logs [erddap|api|proxy]" ;;
  esac
}

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  stop) cmd_stop ;;
  start) cmd_start ;;
  restart) cmd_restart ;;
  status) cmd_status ;;
  logs) shift; cmd_logs "$@" ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
