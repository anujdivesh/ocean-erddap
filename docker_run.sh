#!/usr/bin/env bash
# Run ERDDAP locally with Docker (development).
#   ERDDAP:              http://localhost:8080/erddap
#   Push API:            http://localhost:8080/api   (docs: /api/docs)
#   HTTPS / logins:      https://localhost:8443/erddap  (self-signed cert: accept the browser warning)
#
# Settings come from .env (the single config file); only URLs, data directory and
# email are overridden for localhost. A Caddy container routes /api/* to the Push
# API and everything else to ERDDAP, on 8080 (HTTP) and 8443 (HTTPS; ERDDAP logins
# need HTTPS). Stop with Ctrl+C (the proxy and API containers are stopped too).
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "ERROR: missing .env (create it: cp .env.template .env)" >&2; exit 1; }
PUSH_ADMIN_ROLES="$(grep -E '^PUSH_ADMIN_ROLES=' .env | cut -d= -f2- || true)"
PUSH_MAX_UPLOAD_MB="$(grep -E '^PUSH_MAX_UPLOAD_MB=' .env | cut -d= -f2- || true)"
ERDDAP_IMAGE="$(grep -E '^ERDDAP_IMAGE=' .env | cut -d= -f2- || true)"

NET=erddap_dev
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

cleanup() { docker rm -f erddap_https erddap_push_api >/dev/null 2>&1 || true; }
cleanup
trap cleanup EXIT

# Push API (FastAPI) — shares ERDDAP's users, datasets folder and reload flags
docker build -q -t erddap-push-api ./api >/dev/null
mkdir -p erddap/data/flag
docker run -d --rm \
   --name erddap_push_api \
   --network "$NET" \
   -e PUSH_ADMIN_ROLES="${PUSH_ADMIN_ROLES:-spc}" \
   -e MAX_UPLOAD_MB="${PUSH_MAX_UPLOAD_MB:-500}" \
   -v "$(pwd)/erddap/content:/erddap_content:ro" \
   -v "$(pwd)/datasets:/datasets" \
   -v "$(pwd)/erddap/data/flag:/erddapData/flag" \
  erddap-push-api >/dev/null

# Front door: HTTP 8080 + HTTPS 8443 (directory mount, so Caddyfile edits are seen)
docker run -d --rm \
   --name erddap_https \
   --network "$NET" \
   -p 8080:8080 \
   -p 8443:8443 \
   -v "$(pwd)/deploy/caddy:/etc/caddy:ro" \
   -v erddap_caddy_data:/data \
  caddy:2.8.4 caddy run --config /etc/caddy/Caddyfile.dev --adapter caddyfile >/dev/null

docker run --rm \
   --name erddap_gold_standard \
   --network "$NET" \
   --env-file .env \
   -e ERDDAP_baseUrl="http://localhost:8080" \
   -e ERDDAP_baseHttpsUrl="https://localhost:8443" \
   -e ERDDAP_bigParentDirectory="/erddapData/" \
   -e ERDDAP_MIN_MEMORY="1G" \
   -e ERDDAP_MAX_MEMORY="2G" \
   -e ERDDAP_emailEverythingTo="this+goes+nowhere@doesnotexist.ioos.us" \
   -e ERDDAP_emailDailyReportsTo="" \
   -e ERDDAP_emailSmtpHost="" \
   -v "$(pwd)/erddap/conf/robots.txt:/usr/local/tomcat/webapps/ROOT/robots.txt" \
   -v "$(pwd)/erddap/content:/usr/local/tomcat/content/erddap" \
   -v "$(pwd)/erddap/data:/erddapData" \
   -v "$(pwd)/datasets:/datasets" \
  "${ERDDAP_IMAGE:-erddap/erddap:v2.30.0}"   # v2.30.0: :latest (2.31.1) fails to copy erddap2.css on a fresh container
