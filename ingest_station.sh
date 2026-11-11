#!/usr/bin/env bash
# Pull the latest observations for a station from the SPC ocean-obs API and
# append any NEW records to monthly CSV files that ERDDAP serves.
#
#   ./ingest_station.sh                       # defaults: SPOT-0403 -> datasets/spot-0403
#   ./ingest_station.sh SPOT-0403 spot_0403   # STATION_ID [ERDDAP_DATASET_ID]
#
# Run hourly from cron, e.g. (crontab -e):
#   5 * * * * /path/to/erddap-gold-standard/ingest_station.sh >> /path/to/erddap-gold-standard/logs/ingest_spot0403.log 2>&1
#
# Output: datasets/<station-lowercase>/<STATION>_YYYY-MM.csv
#   columns: station,time,latitude,longitude,significant_wave_height,peak_wave_period,peak_wave_direction
# Safe to re-run any time: records already on disk (same time) are skipped.
# Requires: bash, curl, python3 (standard library only).
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"

STATION_ID="${1:-SPOT-0403}"
DATASET_ID="${2:-$(echo "$STATION_ID" | tr 'A-Z-' 'a-z_')}"   # SPOT-0403 -> spot_0403
LIMIT="${INGEST_LIMIT:-100}"   # 100 records ~ 2 days at 30-min sampling: covers missed runs
API_URL="https://ocean-obs-api.spc.int/insitu/get_data/station/${STATION_ID}?limit=${LIMIT}"
OUT_DIR="${ROOT}/datasets/$(echo "$STATION_ID" | tr 'A-Z' 'a-z')"
FLAG_DIR="${ERDDAP_FLAG_DIR:-${ROOT}/erddap/data/flag}"   # local.sh: deploy/.local/erddapData/flag

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$STATION_ID] $*"; }

# --- single instance lock (portable: mkdir is atomic) ------------------------
LOCK="${TMPDIR:-/tmp}/ingest_${DATASET_ID}.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  log "another run is in progress ($LOCK); exiting"; exit 0
fi
TMP_JSON="$(mktemp)"
trap 'rm -rf "$LOCK" "$TMP_JSON"' EXIT

# --- fetch -------------------------------------------------------------------
if ! curl -fsS --retry 3 --retry-delay 10 --max-time 120 -o "$TMP_JSON" "$API_URL"; then
  log "ERROR: download failed: $API_URL"; exit 1
fi

mkdir -p "$OUT_DIR"

# --- convert + merge (only new timestamps are added) -------------------------
added="$(python3 -I - "$TMP_JSON" "$OUT_DIR" "$STATION_ID" <<'PY'
import csv, json, os, sys, tempfile
from datetime import datetime, timezone

src, out_dir, station = sys.argv[1], sys.argv[2], sys.argv[3]
COLS = ["station", "time", "latitude", "longitude",
        "significant_wave_height", "peak_wave_period", "peak_wave_direction"]

with open(src) as f:
    doc = json.load(f)
lat, lon = doc.get("latitude"), doc.get("longitude")
records = doc.get("data") or []

def num(v):
    if v is None or v == "":
        return ""
    try:
        return repr(float(v))
    except (TypeError, ValueError):
        return ""

# group incoming rows by month file
by_month = {}
for r in records:
    t = r.get("time")
    if not t:
        continue
    try:
        dt = datetime.fromisoformat(t.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        continue
    iso = dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    row = {"station": station, "time": iso,
           "latitude": num(lat), "longitude": num(lon),
           "significant_wave_height": num(r.get("significant_wave_height")),
           "peak_wave_period": num(r.get("peak_wave_period")),
           "peak_wave_direction": num(r.get("peak_wave_direction"))}
    by_month.setdefault(dt.strftime("%Y-%m"), {})[iso] = row

total_new = 0
for month, incoming in by_month.items():
    path = os.path.join(out_dir, f"{station}_{month}.csv")
    existing = {}
    if os.path.exists(path):
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                existing[row["time"]] = row
    new = {k: v for k, v in incoming.items() if k not in existing}
    if not new:
        continue
    existing.update(new)
    total_new += len(new)
    # atomic write: ERDDAP never sees a half-written file
    fd, tmp = tempfile.mkstemp(dir=out_dir, prefix=".tmp_", suffix=".csv")
    with os.fdopen(fd, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS)
        w.writeheader()
        for k in sorted(existing):
            w.writerow({c: existing[k].get(c, "") for c in COLS})
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)

print(total_new)
PY
)"

if [ "$added" -gt 0 ]; then
  log "added $added new record(s) to $OUT_DIR"
  # Ask ERDDAP to reload the dataset now (best effort; it also polls for changes).
  if [ -d "$FLAG_DIR" ] && [ -w "$FLAG_DIR" ]; then
    touch "${FLAG_DIR}/${DATASET_ID}"
  fi
else
  log "no new records"
fi
