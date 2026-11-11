#!/usr/bin/env bash
# Push what git does NOT carry to the production server (over SSH).
#
#   deploy/push.sh            .env + datasets/            (default: "all")
#   deploy/push.sh env        .env only (remote copy is backed up first)
#   deploy/push.sh data       datasets/ only (never overwrites newer files on the server)
#   deploy/push.sh code       repo files incl. uncommitted ones (when the server has no git checkout)
#   deploy/push.sh everything code + .env + datasets/
#
# Options (after the command):
#   --dry-run   show what would be sent, change nothing
#   --up        run "deploy/prod.sh up" on the server afterwards
#
# Uses rsync over ssh (only changed files are sent). Fill in the server below, or
# override per run: DEPLOY_HOST=10.0.0.5 deploy/push.sh env
set -euo pipefail

# ============================ SERVER DETAILS ================================ #
DEPLOY_USER="${DEPLOY_USER:-CHANGE_ME_user}"          # ssh user on the server
DEPLOY_HOST="${DEPLOY_HOST:-CHANGE_ME_host}"          # e.g. erddap.spc.int or 10.0.0.5
DEPLOY_PORT="${DEPLOY_PORT:-22}"                      # ssh port
DEPLOY_PATH="${DEPLOY_PATH:-CHANGE_ME_/srv/erddap-gold-standard}"  # repo folder on the server
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-}"                  # optional: ~/.ssh/id_ed25519
# Give datasets/ to uid 1000 (ERDDAP + Push API) after pushing data. Needs sudo on the server.
DEPLOY_CHOWN_DATA="${DEPLOY_CHOWN_DATA:-false}"
# =========================================================================== #

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

CMD="${1:-all}"; shift || true
DRY=false; UP=false
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=true ;;
    --up) UP=true ;;
    *) die "unknown option: $a" ;;
  esac
done

[[ "$DEPLOY_USER$DEPLOY_HOST$DEPLOY_PATH" == *CHANGE_ME* ]] && \
  die "fill in DEPLOY_USER / DEPLOY_HOST / DEPLOY_PATH at the top of $0 (or set them as environment variables)"
command -v rsync >/dev/null || die "rsync is required (macOS/Linux have it; install it on the server too)"

SSH=(ssh -p "$DEPLOY_PORT" -o ServerAliveInterval=30)
[ -n "$DEPLOY_SSH_KEY" ] && SSH+=(-i "$DEPLOY_SSH_KEY")
REMOTE="${DEPLOY_USER}@${DEPLOY_HOST}"
RSYNC=(rsync -az --human-readable --itemize-changes -e "${SSH[*]}")
$DRY && RSYNC+=(--dry-run)

remote() { "${SSH[@]}" "$REMOTE" "$@"; }

check_remote() {
  log "Connecting to ${REMOTE}:${DEPLOY_PATH}"
  remote "mkdir -p '$DEPLOY_PATH/datasets'" || die "cannot reach ${REMOTE} or create ${DEPLOY_PATH}"
}

push_env() {
  [ -f .env ] || die "no .env here (cp .env.template .env)"
  if grep -q '^[^#]*CHANGE_ME' .env; then
    echo "WARNING: .env still has CHANGE_ME values; deploy/prod.sh up will refuse to start until fixed." >&2
  fi
  log "Pushing .env (remote copy backed up as .env.bak-<timestamp>)"
  if ! $DRY; then
    remote "cd '$DEPLOY_PATH' && [ -f .env ] && cp -p .env .env.bak-\$(date +%Y%m%d-%H%M%S) || true"
  fi
  "${RSYNC[@]}" .env "${REMOTE}:${DEPLOY_PATH}/.env"
  $DRY || remote "chmod 600 '$DEPLOY_PATH/.env'"
}

push_data() {
  log "Pushing datasets/ (files newer on the server are kept; nothing is deleted)"
  "${RSYNC[@]}" --update --exclude '.tmp_*' --exclude '.upload_*' \
    datasets/ "${REMOTE}:${DEPLOY_PATH}/datasets/"
  # readable by ERDDAP (portable: older rsync on macOS has no --chmod)
  $DRY || remote "chmod -R u+rwX,go+rX,go-w '$DEPLOY_PATH/datasets'"
  if [ "$DEPLOY_CHOWN_DATA" = "true" ] && ! $DRY; then
    log "chown datasets/ to 1000:1000 (sudo)"
    remote "sudo chown -R 1000:1000 '$DEPLOY_PATH/datasets'"
  fi
}

push_code() {
  # Everything git would commit (tracked + new files), minus anything gitignored.
  command -v git >/dev/null || die "git is required for 'code'"
  local list; list="$(mktemp)"
  git ls-files -co --exclude-standard -z | grep -zv '^datasets/' > "$list" || true
  log "Pushing code: $(tr -cd '\0' < "$list" | wc -c | tr -d ' ') files (tracked + uncommitted, excluding gitignored and datasets/)"
  "${RSYNC[@]}" --from0 --files-from="$list" ./ "${REMOTE}:${DEPLOY_PATH}/"
  rm -f "$list"
  $DRY || remote "cd '$DEPLOY_PATH' && chmod +x deploy/*.sh ingest_station.sh docker_run.sh 2>/dev/null || true"
}

check_remote
case "$CMD" in
  all)        push_env; push_data ;;
  env)        push_env ;;
  data)       push_data ;;
  code)       push_code ;;
  everything) push_code; push_env; push_data ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

if $UP; then
  if $DRY; then
    log "(dry run) would run: deploy/prod.sh up on the server"
  else
    log "Running deploy/prod.sh up on the server"
    remote "cd '$DEPLOY_PATH' && deploy/prod.sh up"
  fi
fi
if $DRY; then log "Done (dry run: nothing was changed)"; else log "Done"; fi
