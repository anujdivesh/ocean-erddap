# ERDDAP Push API

Upload data files to SPC ERDDAP datasets from anywhere. A file you upload appears in
ERDDAP within seconds.

**Base URL:** `https://erddap.spc.int/api`

## What you need

1. **An account**: a username and password from the ERDDAP administrator. It is the same
   login as the ERDDAP website.
2. **Permission for your dataset**: the administrator gives your account access to one or
   more datasets.
3. **The dataset ID and its file-name pattern**: ask the administrator, or look them up
   with `GET /api/datasets` (step 1 below).

The API only works over **HTTPS**. Your password is sent with every request.

## Quick start

```bash
# 1. Check your login and see which datasets you can push to
curl -u USER:PASSWORD https://erddap.spc.int/api/datasets

# 2. Upload a file
curl -u USER:PASSWORD -F file=@SPOT-0403_2026-11.csv \
     https://erddap.spc.int/api/datasets/spot_0403/files

# 3. Replace a file you uploaded before
curl -u USER:PASSWORD -F file=@SPOT-0403_2026-11.csv \
     "https://erddap.spc.int/api/datasets/spot_0403/files?overwrite=true"
```

Replace `USER:PASSWORD`, the dataset ID (`spot_0403`) and the file name with your own.

## Endpoints

All endpoints except `/api/health` need your login.

| Method | Path | What it does |
|---|---|---|
| GET | `/api/health` | Is the API up? Returns `{"status": "ok"}`. No login. |
| GET | `/api/whoami` | Checks your login. Returns your username and roles. |
| GET | `/api` | Full reference (JSON): every endpoint, rules and error codes. |
| GET | `/api/datasets` | Datasets you may push to, with the file-name pattern each one accepts. |
| GET | `/api/datasets/{id}/files` | Files currently in the dataset (name, size, last modified). |
| POST | `/api/datasets/{id}/files` | Upload a file. Add `?overwrite=true` to replace an existing one. |
| DELETE | `/api/datasets/{id}/files/{name}` | Delete a file. |
| POST | `/api/datasets/{id}/reload` | Ask ERDDAP to reload the dataset now. Rarely needed: uploads and deletes do this already. |

## Upload rules

- Send the file as the multipart form field named **`file`** (`curl -F file=@...`).
- The **file name must match the dataset's pattern** (`fileNameRegex` in `GET /api/datasets`).
  For example, `SPOT-0403_\d{4}-\d{2}\.csv` accepts `SPOT-0403_2026-11.csv`.
- Names may contain only letters, digits, `.`, `_` and `-`. No folders.
- An existing file is **not replaced** unless you add `?overwrite=true`.
- Maximum size: **500 MB** per file.
- The file must have the same columns and format as the dataset's other files.
  ERDDAP skips a file it cannot read.

## Example responses

Upload (`201 Created`):
```json
{
  "datasetID": "spot_0403",
  "file": {"name": "SPOT-0403_2026-11.csv", "bytes": 7097, "modified": "2026-11-12T03:29:36Z"},
  "replaced": false,
  "reload_requested": true
}
```

`GET /api/datasets`:
```json
[{"datasetID": "spot_0403", "type": "EDDTableFromAsciiFiles", "active": true,
  "fileNameRegex": "SPOT-0403_\\d{4}-\\d{2}\\.csv"}]
```

## Errors

Errors return JSON like `{"detail": "what went wrong"}`.

| Code | Meaning | What to do |
|---|---|---|
| 400 | Bad file name, name doesn't match the dataset's pattern, or empty file | Rename the file to match `fileNameRegex` |
| 401 | Missing or wrong username/password | Check your login with `GET /api/whoami` |
| 403 | Logged in, but not allowed to push to this dataset | Ask the administrator for access |
| 404 | Unknown dataset or file | Check the dataset ID with `GET /api/datasets` |
| 409 | File already exists | Add `?overwrite=true` to replace it |
| 411 | Upload sent without a `Content-Length` header | Use `curl -F` or Python `requests` (both send it) |
| 413 | File larger than 500 MB | Split the file (e.g. one file per month) |
| 429 | Too many failed logins from your address (10 in 15 minutes) | Wait 15 minutes, then fix the password |

## Python example

```python
import requests

BASE = "https://erddap.spc.int/api"
AUTH = ("USER", "PASSWORD")   # better: read these from environment variables

# Datasets I can push to
print(requests.get(f"{BASE}/datasets", auth=AUTH, timeout=30).json())

# Upload (replace if it already exists)
with open("SPOT-0403_2026-11.csv", "rb") as f:
    r = requests.post(
        f"{BASE}/datasets/spot_0403/files",
        params={"overwrite": "true"},
        files={"file": f},
        auth=AUTH,
        timeout=300,
    )
r.raise_for_status()
print(r.json())
```

## Automating uploads (e.g. hourly)

Keep the password out of scripts. Put it in environment variables instead:

```bash
#!/usr/bin/env bash
# push_latest.sh, run from cron: 5 * * * * /path/push_latest.sh
set -euo pipefail
FILE="SPOT-0403_$(date -u +%Y-%m).csv"
curl -fsS -u "$ERDDAP_USER:$ERDDAP_PASS" -F "file=@$FILE" \
     "https://erddap.spc.int/api/datasets/spot_0403/files?overwrite=true"
```

`curl -f` makes the script fail on errors (401, 413, ...), so cron can report them.

## Good to know

- **The newest upload wins.** If two senders write the same file name, the second upload
  replaces the first. Use a separate file per sender or per month.
- **Uploads are all-or-nothing.** ERDDAP never sees a half-uploaded file.
- **Deleting a file removes its data from ERDDAP** at the next reload, which happens
  automatically.
- **New datasets can't be created through the API.** Ask the ERDDAP administrator.
