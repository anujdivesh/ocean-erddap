# Deployment

| Script | Use | Needs |
|---|---|---|
| `deploy/prod.sh` | Production server: ERDDAP + Push API + HTTPS (Docker) | Docker |
| `deploy/push.sh` | Copy what git doesn't carry (`.env`, `datasets/`, uncommitted code) to the server | ssh, rsync |
| `deploy/local.sh` | Local development without Docker | curl, unzip, python3 |
| `docker_run.sh` (repo root) | Local development with Docker | Docker |

## Configuration: one file

All scripts read **`.env`** in the repo root (gitignored, holds secrets).
Start from the committed template:

```bash
cp .env.template .env      # then fill in every CHANGE_ME
```

Local scripts reuse `.env` and only override URLs, ports, memory and email for localhost.
`erddap/conf/config.sh` is the upstream repo's file and is no longer used by these scripts.

## Production (`deploy/prod.sh`)

1. On the server: Docker installed, repo checked out (or pushed with `deploy/push.sh code`).
2. `.env`: set `DOMAIN` (e.g. `erddap.spc.int`), `TLS_MODE`, and every `CHANGE_ME`.
3. `sudo chown -R 1000:1000 datasets/` (ERDDAP and the Push API run as uid 1000).
4. `deploy/prod.sh up`

HTTPS (`TLS_MODE` in `.env`):

| Mode | What happens | Requirements |
|---|---|---|
| `auto` (default) | A Caddy container gets and renews a Let's Encrypt certificate for `DOMAIN` | DNS for `DOMAIN` points at the server; ports 80 + 443 open to the internet |
| `certfiles` | Caddy serves your certificate | `TLS_CERT_FILE` (full chain) and `TLS_KEY_FILE` paths on the server |
| `external` | No Caddy; the main nginx terminates HTTPS | Use `deploy/nginx/erddap.spc.int.conf` |
| `internal` | Self-signed certificate | Testing only |

Public URLs: `https://DOMAIN/erddap/` (ERDDAP), `https://DOMAIN/api/` (Push API),
`https://DOMAIN/` redirects to `/erddap/`, HTTP redirects to HTTPS.

```bash
deploy/prod.sh up        # validate .env, pull/build, (re)create, start
deploy/prod.sh status    # containers + HTTP/HTTPS health checks
deploy/prod.sh logs api  # follow logs: erddap | api | proxy
deploy/prod.sh stop      # stop, keep containers  -> deploy/prod.sh start
deploy/prod.sh restart
deploy/prod.sh down      # remove containers (data, config and certificates kept)
```

Run `up` again after changing `.env` or the code. Containers restart automatically after
a crash or reboot. Certificates persist in the Docker volume `<CONTAINER_NAME>_caddy_data`.

## Pushing to the server (`deploy/push.sh`)

Fill in `DEPLOY_USER`, `DEPLOY_HOST`, `DEPLOY_PATH` (and optionally `DEPLOY_PORT`,
`DEPLOY_SSH_KEY`) at the top of the script once.

```bash
deploy/push.sh                  # .env + datasets/
deploy/push.sh env              # .env only (server copy backed up first, chmod 600)
deploy/push.sh data             # datasets/ (never overwrites newer files on the server, never deletes)
deploy/push.sh code             # all repo files incl. uncommitted ones (no git needed on the server)
deploy/push.sh everything --up  # code + .env + data, then deploy/prod.sh up on the server
deploy/push.sh all --dry-run    # show what would be sent
```

## Local without Docker (`deploy/local.sh`)

```bash
deploy/local.sh install   # one time: Java 25, DejaVu fonts, Tomcat 11.0.18, ERDDAP 2.30.0 (~1 GB) into deploy/.local
deploy/local.sh start     # ERDDAP http://localhost:8080/erddap, API http://localhost:8000/api
deploy/local.sh sync      # after editing datasets.xml / setup.xml
deploy/local.sh status | logs [erddap|api] | stop | restart | uninstall
```

- Other ports: `LOCAL_PORT=8091 LOCAL_API_PORT=8002 deploy/local.sh start` (stop the Docker stack first if it uses 8080).
- `datasets.xml` keeps container paths (`/datasets/...`); the runtime copy points them at
  this repo's `datasets/`, so one `datasets.xml` works everywhere.
- ERDDAP website logins are disabled in this mode (no HTTPS). Push API logins work.

## What to back up

`datasets/`, `.env`, `erddap/content/`, `erddap/conf/`. Everything in `erddap/data/` and
`deploy/.local/` is regenerated.
