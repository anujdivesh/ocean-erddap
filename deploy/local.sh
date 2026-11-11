#!/usr/bin/env bash
# Local ERDDAP + Push API WITHOUT Docker (macOS or Linux).
#
#   deploy/local.sh install   download Java, Tomcat and ERDDAP into deploy/.local and set up the API
#   deploy/local.sh start     start ERDDAP (Tomcat) and the Push API in the background
#   deploy/local.sh stop      stop both
#   deploy/local.sh restart   stop + start
#   deploy/local.sh status    show what is running
#   deploy/local.sh sync      re-copy erddap/content after you edit datasets.xml/setup.xml, and reload datasets
#   deploy/local.sh logs [erddap|api]   follow logs (default: erddap)
#   deploy/local.sh uninstall remove deploy/.local (downloads, runtime data, logs)
#
# Same versions as the Docker image: Java 25 (Temurin), Tomcat 11.0.18, ERDDAP 2.30.0.
# Everything lives in deploy/.local (gitignored). Nothing is installed system-wide.
#
#   ERDDAP:   http://localhost:${LOCAL_PORT:-8080}/erddap
#   Push API: http://localhost:${LOCAL_API_PORT:-8000}/api
#
# Notes
# * datasets.xml uses container paths (<fileDir>/datasets/...). The runtime copy in
#   deploy/.local/content rewrites them to this repo's datasets/ folder, so the same
#   datasets.xml works in Docker and here. Run "sync" after editing it.
# * ERDDAP logins need HTTPS, which this mode does not provide, so the runtime copy
#   disables <authentication>. The Push API still uses the <user> logins.
# * Settings (admin contact, flagKeyKey, Push API roles, ...) come from .env; URLs,
#   data directory, memory and email are overridden for localhost.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="${ROOT}/deploy/.local"

ERDDAP_VERSION="2.30.0"
TOMCAT_VERSION="11.0.18"
JAVA_MAJOR="25"
PORT="${LOCAL_PORT:-8080}"
API_PORT="${LOCAL_API_PORT:-8000}"
SHUTDOWN_PORT="${LOCAL_SHUTDOWN_PORT:-8005}"

JDK_DIR="$L/jdk"
CATALINA_HOME="$L/tomcat"
CONTENT="$L/content"
DATA="$L/erddapData"
VENV="$L/venv"
DL="$L/downloads"
LOGS="$L/logs"
TOMCAT_PID="$L/tomcat.pid"
API_PID="$L/api.pid"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }
fetch() { curl -fL --retry 3 --progress-bar -o "$2" "$1"; }

sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
sha512_of() { if command -v sha512sum >/dev/null; then sha512sum "$1" | cut -d' ' -f1; else shasum -a 512 "$1" | cut -d' ' -f1; fi; }

running() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

java_home() {
  # Prefer an explicit JAVA_HOME with Java >= 21, else the bundled JDK.
  if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    local v; v="$("$JAVA_HOME/bin/java" -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+).*/\1/')"
    if [ "${v:-0}" -ge 21 ]; then echo "$JAVA_HOME"; return; fi
  fi
  local j; j="$(find "$JDK_DIR" -maxdepth 6 -type f -path '*/bin/java' 2>/dev/null | head -1)"
  [ -n "$j" ] || die "Java not installed; run: $0 install"
  dirname "$(dirname "$j")"
}

# --------------------------------------------------------------------------- #
install_java() {
  if [ -n "$(find "$JDK_DIR" -maxdepth 6 -type f -path '*/bin/java' 2>/dev/null | head -1)" ]; then
    log "Java already installed"; return
  fi
  local os arch meta link sum file
  case "$(uname -s)" in Darwin) os=mac ;; Linux) os=linux ;; *) die "unsupported OS" ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=aarch64 ;; x86_64|amd64) arch=x64 ;; *) die "unsupported CPU" ;; esac
  log "Downloading Temurin JDK ${JAVA_MAJOR} (${os}/${arch})"
  meta="$(curl -fsS "https://api.adoptium.net/v3/assets/latest/${JAVA_MAJOR}/hotspot?architecture=${arch}&image_type=jdk&os=${os}&vendor=eclipse")"
  link="$(printf '%s' "$meta" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[0]["binary"]["package"]["link"])')"
  sum="$(printf '%s' "$meta" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[0]["binary"]["package"]["checksum"])')"
  file="$DL/jdk.tar.gz"
  fetch "$link" "$file"
  [ "$(sha256_of "$file")" = "$sum" ] || die "JDK checksum mismatch"
  rm -rf "$JDK_DIR"; mkdir -p "$JDK_DIR"
  tar -xzf "$file" -C "$JDK_DIR"
  rm -f "$file"
}

install_tomcat() {
  if [ -x "$CATALINA_HOME/bin/catalina.sh" ]; then log "Tomcat already installed"; return; fi
  local base="https://archive.apache.org/dist/tomcat/tomcat-11/v${TOMCAT_VERSION}/bin"
  local file="$DL/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
  log "Downloading Tomcat ${TOMCAT_VERSION}"
  fetch "$base/apache-tomcat-${TOMCAT_VERSION}.tar.gz" "$file"
  [ "$(sha512_of "$file")" = "$(curl -fsS "$base/apache-tomcat-${TOMCAT_VERSION}.tar.gz.sha512" | cut -d' ' -f1)" ] \
    || die "Tomcat checksum mismatch"
  rm -rf "$CATALINA_HOME"; mkdir -p "$CATALINA_HOME"
  tar -xzf "$file" -C "$CATALINA_HOME" --strip-components=1
  rm -f "$file"
  # Only ERDDAP and a minimal ROOT (for robots.txt)
  rm -rf "$CATALINA_HOME/webapps/"{docs,examples,manager,host-manager}
  rm -rf "$CATALINA_HOME/webapps/ROOT"; mkdir -p "$CATALINA_HOME/webapps/ROOT"
}

install_erddap() {
  if [ -f "$CATALINA_HOME/webapps/erddap/WEB-INF/web.xml" ]; then log "ERDDAP already installed"; return; fi
  local war="$DL/ERDDAP-${ERDDAP_VERSION}.war"
  if [ ! -s "$war" ]; then
    log "Downloading ERDDAP ${ERDDAP_VERSION} (~700 MB, one time)"
    fetch "https://github.com/ERDDAP/erddap/releases/download/v${ERDDAP_VERSION}/ERDDAP-${ERDDAP_VERSION}.war" "$war.part"
    mv "$war.part" "$war"
  fi
  log "Unpacking ERDDAP"
  rm -rf "$CATALINA_HOME/webapps/erddap"; mkdir -p "$CATALINA_HOME/webapps/erddap"
  unzip -q "$war" -d "$CATALINA_HOME/webapps/erddap"
}

install_api() {
  if [ ! -x "$VENV/bin/uvicorn" ]; then
    log "Creating Python environment for the Push API"
    python3 -m venv "$VENV"
  fi
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q -r "$ROOT/api/requirements.txt"
}

install_fonts() {
  # ERDDAP draws graphs with DejaVu fonts; Java loads extra fonts from <JDK>/lib/fonts.
  local fonts; fonts="$(java_home)/lib/fonts"
  if ls "$fonts"/DejaVuSans*.ttf >/dev/null 2>&1; then log "DejaVu fonts already installed"; return; fi
  log "Installing DejaVu fonts (needed for ERDDAP graphs)"
  local zip="$DL/dejavu-fonts.zip"
  fetch "https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-2.37.zip" "$zip"
  mkdir -p "$fonts"
  unzip -q -j -o "$zip" 'dejavu-fonts-ttf-2.37/ttf/*.ttf' -d "$fonts"
  rm -f "$zip"
}

cmd_install() {
  command -v curl >/dev/null || die "curl is required"
  command -v unzip >/dev/null || die "unzip is required"
  command -v python3 >/dev/null || die "python3 is required"
  mkdir -p "$DL" "$LOGS" "$DATA"
  install_java
  install_fonts
  install_tomcat
  install_erddap
  install_api
  log "Installed in $L"
  echo "Next: $0 start"
}

# --------------------------------------------------------------------------- #
# Build the runtime content dir from erddap/content (paths rewritten for this host)
cmd_sync() {
  [ -d "$CATALINA_HOME" ] || die "not installed; run: $0 install"
  mkdir -p "$CONTENT"
  rm -rf "$CONTENT/images"
  cp -R "$ROOT/erddap/content/images" "$CONTENT/images" 2>/dev/null || true
  python3 -I - "$ROOT/erddap/content" "$CONTENT" "$ROOT/datasets" <<'PY'
import os, re, sys
src, dst, datasets = sys.argv[1], sys.argv[2], sys.argv[3].rstrip("/")

def write(name, text):
    tmp = os.path.join(dst, f".{name}.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, os.path.join(dst, name))

with open(os.path.join(src, "datasets.xml"), encoding="utf-8") as f:
    ds = f.read()
# <fileDir>/datasets/...</fileDir>  ->  <fileDir>/path/to/repo/datasets/...</fileDir>
ds = re.sub(r"(<fileDir>\s*)/datasets(/|\s*</fileDir>)", lambda m: m.group(1) + datasets + m.group(2), ds)
write("datasets.xml", ds)

with open(os.path.join(src, "setup.xml"), encoding="utf-8") as f:
    st = f.read()
# No HTTPS in this mode -> ERDDAP refuses to start with logins enabled.
st = re.sub(r"<authentication>[^<]*</authentication>", "<authentication></authentication>", st)
write("setup.xml", st)

for extra in ("messages.xml",):
    p = os.path.join(src, extra)
    if os.path.exists(p):
        with open(p, encoding="utf-8") as f:
            write(extra, f.read())
PY
  cp "$ROOT/erddap/conf/robots.txt" "$CATALINA_HOME/webapps/ROOT/robots.txt"
  # Ask ERDDAP to reload every dataset (no-op if ERDDAP isn't running)
  mkdir -p "$DATA/flag"
  { grep -o 'datasetID="[^"]*"' "$CONTENT/datasets.xml" || true; } | cut -d'"' -f2 | while read -r id; do
    [ -n "$id" ] && touch "$DATA/flag/$id"
  done
  log "Synced erddap/content -> $CONTENT"
}

load_env() {
  # Settings from .env (the single config file), read literally.
  local f="$ROOT/.env"
  [ -f "$f" ] || die "missing $f (create it: cp .env.template .env)"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    case "${BASH_REMATCH[1]}" in
      ERDDAP_*|PUSH_*) export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}" ;;
    esac
  done < "$f"
}

erddap_env() {
  # .env, then local overrides (URLs, data dir, memory, no email).
  load_env
  export ERDDAP_baseUrl="http://localhost:${PORT}"
  export ERDDAP_baseHttpsUrl="http://localhost:${PORT}"
  export ERDDAP_bigParentDirectory="${DATA}/"
  export ERDDAP_MIN_MEMORY="${LOCAL_MIN_MEMORY:-1G}" ERDDAP_MAX_MEMORY="${LOCAL_MAX_MEMORY:-2G}"
  export ERDDAP_emailEverythingTo="this+goes+nowhere@doesnotexist.ioos.us"
  export ERDDAP_emailDailyReportsTo="" ERDDAP_emailSmtpHost=""
  export JAVA_HOME; JAVA_HOME="$(java_home)"
  export CATALINA_HOME CATALINA_BASE="$CATALINA_HOME" CATALINA_PID="$TOMCAT_PID"
  export CATALINA_OPTS="-server -Djava.awt.headless=true -Xms${ERDDAP_MIN_MEMORY:-1G} -Xmx${ERDDAP_MAX_MEMORY:-2G} -XX:+HeapDumpOnOutOfMemoryError -DerddapContentDirectory=${CONTENT}/"
}

configure_ports() {
  local xml="$CATALINA_HOME/conf/server.xml"
  python3 -I - "$xml" "$PORT" "$SHUTDOWN_PORT" <<'PY'
import re, sys
path, port, shutdown = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding="utf-8").read()
s = re.sub(r'(<Server port=")\d+(")', rf"\g<1>{shutdown}\g<2>", s, count=1)
s = re.sub(r'(<Connector port=")\d+(" protocol="HTTP/1.1")', rf"\g<1>{port}\g<2>", s, count=1)
open(path, "w", encoding="utf-8").write(s)
PY
}

port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

cmd_start() {
  [ -f "$CATALINA_HOME/webapps/erddap/WEB-INF/web.xml" ] || die "not installed; run: $0 install"
  mkdir -p "$LOGS" "$DATA"
  cmd_sync

  if running "$TOMCAT_PID"; then
    log "ERDDAP already running (pid $(cat "$TOMCAT_PID"))"
  else
    port_free "$PORT" || die "port $PORT is in use (Docker stack running?). Stop it or set LOCAL_PORT=..."
    configure_ports
    ( erddap_env; "$CATALINA_HOME/bin/startup.sh" >/dev/null )
    log "ERDDAP starting on http://localhost:${PORT}/erddap"
  fi

  if running "$API_PID"; then
    log "Push API already running (pid $(cat "$API_PID"))"
  else
    port_free "$API_PORT" || die "port $API_PORT is in use. Set LOCAL_API_PORT=..."
    (
      load_env
      cd "$ROOT/api"
      ERDDAP_CONTENT_DIR="$CONTENT" DATASETS_ROOT="$ROOT/datasets" ERDDAP_FLAG_DIR="$DATA/flag" \
      PUSH_ADMIN_ROLES="${PUSH_ADMIN_ROLES:-spc}" MAX_UPLOAD_MB="${PUSH_MAX_UPLOAD_MB:-500}" \
        nohup "$VENV/bin/uvicorn" app.main:app --host 127.0.0.1 --port "$API_PORT" \
        >> "$LOGS/api.log" 2>&1 &
      echo $! > "$API_PID"
    )
    log "Push API starting on http://localhost:${API_PORT}/api"
  fi

  log "Waiting for ERDDAP..."
  for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null "http://localhost:${PORT}/erddap/index.html" 2>/dev/null; then
      cmd_status; return 0
    fi
    running "$TOMCAT_PID" || die "Tomcat exited; see: $0 logs"
    sleep 3
  done
  echo "WARNING: ERDDAP not responding yet; see: $0 logs" >&2
  return 1
}

cmd_stop() {
  if running "$API_PID"; then
    kill "$(cat "$API_PID")" && log "Stopped Push API"
  fi
  rm -f "$API_PID"
  if running "$TOMCAT_PID"; then
    ( erddap_env; "$CATALINA_HOME/bin/shutdown.sh" 30 -force >/dev/null 2>&1 ) || true
    log "Stopped ERDDAP"
  fi
  rm -f "$TOMCAT_PID"
}

cmd_status() {
  if running "$TOMCAT_PID"; then echo "ERDDAP   running (pid $(cat "$TOMCAT_PID"))"; else echo "ERDDAP   stopped"; fi
  if running "$API_PID"; then echo "Push API running (pid $(cat "$API_PID"))"; else echo "Push API stopped"; fi
  printf 'ERDDAP   http://localhost:%s/erddap      -> %s\n' "$PORT" \
    "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/erddap/index.html" || true)"
  printf 'Push API http://localhost:%s/api/health  -> %s\n' "$API_PORT" \
    "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${API_PORT}/api/health" || true)"
}

cmd_logs() {
  case "${1:-erddap}" in
    erddap) exec tail -n 200 -f "$CATALINA_HOME/logs/catalina.out" ;;
    api)    exec tail -n 200 -f "$LOGS/api.log" ;;
    *) die "usage: $0 logs [erddap|api]" ;;
  esac
}

cmd_uninstall() {
  cmd_stop || true
  rm -rf "$L"
  log "Removed $L"
}

case "${1:-}" in
  install) cmd_install ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) cmd_stop; sleep 2; cmd_start ;;
  status) cmd_status ;;
  sync) cmd_sync ;;
  logs) shift; cmd_logs "$@" ;;
  uninstall) cmd_uninstall ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
