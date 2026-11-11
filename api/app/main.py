"""
ERDDAP Push API — upload data files to existing ERDDAP datasets over HTTPS.

Authentication reuses ERDDAP's own user list: the <user username=".." password=".."
roles=".."/> entries in datasets.xml, hashed with <passwordEncoding> from setup.xml.
Clients send HTTP Basic credentials (always over HTTPS, via the reverse proxy).

Authorization:
  * a user with any role in PUSH_ADMIN_ROLES (default "spc") may push to every dataset
  * a user with role "push:<datasetID>" may push to that dataset only

Only file-based datasets (type ...Files) whose <fileDir> is inside DATASETS_ROOT are
pushable. Uploaded file names must match the dataset's <fileNameRegex>, so ERDDAP
will always see them. After any change the dataset's reload flag is set.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import re
import tempfile
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from fastapi import Depends, FastAPI, File, HTTPException, Query, Request, UploadFile, status
from fastapi.responses import JSONResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials

CONTENT_DIR = Path(os.environ.get("ERDDAP_CONTENT_DIR", "/erddap_content"))
DATASETS_ROOT = Path(os.environ.get("DATASETS_ROOT", "/datasets")).resolve()
FLAG_DIR = Path(os.environ.get("ERDDAP_FLAG_DIR", "/erddapData/flag"))
ADMIN_ROLES = {r.strip() for r in os.environ.get("PUSH_ADMIN_ROLES", "spc").split(",") if r.strip()}
MAX_UPLOAD_BYTES = int(os.environ.get("MAX_UPLOAD_MB", "500")) * 1024 * 1024
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$")

app = FastAPI(
    title="ERDDAP Push API",
    description="Upload data files to ERDDAP datasets. Log in with your ERDDAP username/password.",
    version="1.0.0",
    docs_url="/api/docs",
    redoc_url=None,
    openapi_url="/api/openapi.json",
)
security = HTTPBasic(realm="ERDDAP Push API")


# --------------------------------------------------------------------------- #
# ERDDAP configuration (re-read automatically when the XML files change)
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class Dataset:
    dataset_id: str
    type: str
    active: bool
    file_dir: Path
    file_name_regex: str


@dataclass(frozen=True)
class User:
    username: str
    password_hash: str
    roles: frozenset[str]


_cache: dict[str, tuple[tuple, float, object]] = {}
CACHE_MAX_AGE_S = 5  # re-read at least this often, even if the file looks unchanged


def _cached(path: Path, parse):
    st = path.stat()
    key = (st.st_mtime_ns, st.st_size, st.st_ino)
    hit = _cache.get(str(path))
    now = time.monotonic()
    if hit and hit[0] == key and now - hit[1] < CACHE_MAX_AGE_S:
        return hit[2]
    value = parse(path)
    _cache[str(path)] = (key, now, value)
    return value


def _parse_datasets_xml(path: Path) -> tuple[dict[str, User], dict[str, Dataset]]:
    root = ET.parse(path).getroot()
    users: dict[str, User] = {}
    for u in root.findall("user"):
        name = (u.get("username") or "").strip()
        if name:
            roles = frozenset(r.strip() for r in (u.get("roles") or "").split(",") if r.strip())
            users[name] = User(name, (u.get("password") or "").strip().lower(), roles)
    datasets: dict[str, Dataset] = {}
    for d in root.findall("dataset"):
        ds_id, ds_type = d.get("datasetID"), d.get("type") or ""
        file_dir = (d.findtext("fileDir") or "").strip()
        if not ds_id or not ds_type.endswith("Files") or not file_dir:
            continue
        datasets[ds_id] = Dataset(
            dataset_id=ds_id,
            type=ds_type,
            active=(d.get("active", "true").lower() != "false"),
            file_dir=Path(file_dir),
            file_name_regex=(d.findtext("fileNameRegex") or ".*").strip(),
        )
    return users, datasets


def _parse_password_encoding(path: Path) -> str:
    try:
        enc = ET.parse(path).getroot().findtext("passwordEncoding")
    except (ET.ParseError, OSError):
        enc = None
    return (enc or "UEPSHA256").strip().upper()


def erddap_config() -> tuple[dict[str, User], dict[str, Dataset], str]:
    users, datasets = _cached(CONTENT_DIR / "datasets.xml", _parse_datasets_xml)
    encoding = _cached(CONTENT_DIR / "setup.xml", _parse_password_encoding)
    return users, datasets, encoding


def _hash_password(encoding: str, username: str, password: str) -> str:
    uep = f"{username}:ERDDAP:{password}".encode()
    return {
        "UEPSHA256": lambda: hashlib.sha256(uep).hexdigest(),
        "UEPMD5": lambda: hashlib.md5(uep).hexdigest(),
        "SHA256": lambda: hashlib.sha256(password.encode()).hexdigest(),
        "MD5": lambda: hashlib.md5(password.encode()).hexdigest(),
    }.get(encoding, lambda: hashlib.sha256(uep).hexdigest())()


# --------------------------------------------------------------------------- #
# Auth
# --------------------------------------------------------------------------- #
def current_user(creds: HTTPBasicCredentials = Depends(security)) -> User:
    users, _, encoding = erddap_config()
    user = users.get(creds.username)
    candidate = _hash_password(encoding, creds.username, creds.password)
    if user is None or not user.password_hash or not hmac.compare_digest(candidate, user.password_hash):
        time.sleep(1)  # slow down password guessing
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            "Invalid username or password",
            headers={"WWW-Authenticate": 'Basic realm="ERDDAP Push API"'},
        )
    return user


def can_push(user: User, dataset_id: str) -> bool:
    return bool(user.roles & ADMIN_ROLES) or f"push:{dataset_id}" in user.roles


def pushable_dataset(dataset_id: str, user: User = Depends(current_user)) -> Dataset:
    _, datasets, _ = erddap_config()
    ds = datasets.get(dataset_id)
    if ds is None:
        raise HTTPException(404, f"No file-based dataset '{dataset_id}' in datasets.xml")
    if not can_push(user, dataset_id):
        raise HTTPException(403, f"User '{user.username}' may not push to '{dataset_id}'")
    file_dir = ds.file_dir.resolve()
    if file_dir != DATASETS_ROOT and DATASETS_ROOT not in file_dir.parents:
        raise HTTPException(403, f"fileDir {ds.file_dir} is outside {DATASETS_ROOT}; not pushable")
    return ds


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def _check_filename(ds: Dataset, filename: str) -> str:
    name = Path(filename or "").name
    if name != filename or not SAFE_NAME.match(name):
        raise HTTPException(400, "Invalid file name (letters, digits, . _ - only; no paths)")
    try:
        ok = re.fullmatch(ds.file_name_regex, name) is not None
    except re.error:
        ok = False
    if not ok:
        raise HTTPException(
            400, f"File name '{name}' does not match the dataset's fileNameRegex: {ds.file_name_regex}"
        )
    return name


def _request_reload(dataset_id: str) -> bool:
    try:
        (FLAG_DIR / dataset_id).touch()
        return True
    except OSError:
        return False


def _file_info(p: Path) -> dict:
    st = p.stat()
    return {
        "name": p.name,
        "bytes": st.st_size,
        "modified": datetime.fromtimestamp(st.st_mtime, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


# --------------------------------------------------------------------------- #
# Routes
# --------------------------------------------------------------------------- #
_EXAMPLES = {
    ("GET", "/api/health"): "curl {base}/api/health",
    ("GET", "/api/whoami"): "curl -u USER:PASSWORD {base}/api/whoami",
    ("GET", "/api/datasets"): "curl -u USER:PASSWORD {base}/api/datasets",
    ("GET", "/api/datasets/{dataset_id}/files"): "curl -u USER:PASSWORD {base}/api/datasets/spot_0403/files",
    ("POST", "/api/datasets/{dataset_id}/files"): (
        "curl -u USER:PASSWORD -F file=@SPOT-0403_2026-10.csv "
        "\"{base}/api/datasets/spot_0403/files?overwrite=true\""
    ),
    ("DELETE", "/api/datasets/{dataset_id}/files/{filename}"): (
        "curl -u USER:PASSWORD -X DELETE {base}/api/datasets/spot_0403/files/SPOT-0403_2026-10.csv"
    ),
    ("POST", "/api/datasets/{dataset_id}/reload"): (
        "curl -u USER:PASSWORD -X POST {base}/api/datasets/spot_0403/reload"
    ),
}


@app.get("/api", tags=["status"], summary="API documentation (this page)")
@app.get("/api/", include_in_schema=False)
def api_documentation(request: Request):
    """Complete API reference in one response: authentication, permissions, every endpoint
    with parameters and a curl example, and error codes. No login required."""
    from fastapi.dependencies.utils import get_flat_dependant
    from fastapi.routing import APIRoute

    base = str(request.base_url).rstrip("/")
    endpoints = []
    for route in app.routes:
        if not isinstance(route, APIRoute) or not route.include_in_schema:
            continue
        flat = get_flat_dependant(route.dependant)
        for method in sorted(route.methods - {"HEAD", "OPTIONS"}):
            ep = {
                "method": method,
                "path": route.path,
                "summary": route.summary or route.name,
                "description": " ".join((route.description or "").split()),
                "login_required": bool(flat.security_requirements),
            }
            params = {
                "path": [p.name for p in flat.path_params],
                "query": [
                    {"name": p.name, "default": p.default, "description": p.field_info.description}
                    for p in flat.query_params
                ],
                "form": [
                    {"name": p.name, "description": p.field_info.description} for p in flat.body_params
                ],
            }
            params = {k: v for k, v in params.items() if v}
            if params:
                ep["parameters"] = params
            if (method, route.path) in _EXAMPLES:
                ep["example"] = _EXAMPLES[(method, route.path)].format(base=base)
            endpoints.append(ep)

    doc = {
        "name": app.title,
        "version": app.version,
        "description": (
            "Upload, replace, list and delete data files of existing ERDDAP datasets. "
            "ERDDAP reloads a dataset automatically after every change."
        ),
        "base_url": f"{base}/api",
        "interactive_docs": f"{base}/api/docs",
        "openapi_spec": f"{base}/api/openapi.json",
        "authentication": {
            "scheme": "HTTP Basic (curl -u USER:PASSWORD), over HTTPS only",
            "accounts": "Same username/password as the ERDDAP website login "
                        "(<user> entries in ERDDAP's datasets.xml).",
        },
        "permissions": {
            "admin_roles": sorted(ADMIN_ROLES),
            "rules": [
                f"A user with any of the roles {sorted(ADMIN_ROLES)} can push to every file-based dataset.",
                "A user with role 'push:<datasetID>' can push to that dataset only.",
                "GET /api/datasets shows the datasets you are allowed to push to.",
            ],
        },
        "upload_rules": [
            "Send the file as multipart form field 'file'.",
            "The file name must match the dataset's fileNameRegex (see GET /api/datasets).",
            "Names may contain only letters, digits, '.', '_' and '-' (no paths).",
            "An existing file is only replaced with ?overwrite=true.",
            f"Maximum size: {MAX_UPLOAD_BYTES // 1024 // 1024} MB.",
            "Files are written atomically: ERDDAP never sees a partial upload.",
        ],
        "endpoints": endpoints,
        "errors": {
            "400": "Invalid request: bad file name, name not matching fileNameRegex, or empty file",
            "401": "Missing or wrong username/password",
            "403": "Logged in, but not allowed to push to this dataset",
            "404": "Unknown dataset or file",
            "409": "File already exists (add ?overwrite=true)",
            "413": "File too large",
        },
    }
    return JSONResponse(doc, media_type="application/json")


@app.get("/api/health", tags=["status"], summary="Service status")
def health():
    """Returns {"status": "ok"} when the API is up and can read ERDDAP's configuration."""
    erddap_config()  # fails loudly if the XML can't be read
    return {"status": "ok"}


@app.get("/api/whoami", tags=["status"], summary="Check your login")
def whoami(user: User = Depends(current_user)):
    """Returns your username and ERDDAP roles. Use it to test credentials."""
    return {"username": user.username, "roles": sorted(user.roles)}


@app.get("/api/datasets", tags=["datasets"], summary="List datasets you can push to")
def list_datasets(user: User = Depends(current_user)):
    """File-based ERDDAP datasets your roles allow you to push to, with the fileNameRegex uploads must match."""
    _, datasets, _ = erddap_config()
    return [
        {
            "datasetID": d.dataset_id,
            "type": d.type,
            "active": d.active,
            "fileNameRegex": d.file_name_regex,
        }
        for d in sorted(datasets.values(), key=lambda d: d.dataset_id)
        if can_push(user, d.dataset_id)
    ]


@app.get("/api/datasets/{dataset_id}/files", tags=["files"], summary="List a dataset's files")
def list_files(ds: Dataset = Depends(pushable_dataset)):
    """Data files ERDDAP currently serves for the dataset: name, size in bytes, last modified (UTC)."""
    if not ds.file_dir.is_dir():
        return []
    rx = re.compile(ds.file_name_regex)
    return [_file_info(p) for p in sorted(ds.file_dir.iterdir()) if p.is_file() and rx.fullmatch(p.name)]


@app.post("/api/datasets/{dataset_id}/files", status_code=201, tags=["files"], summary="Upload a data file")
def upload_file(
    file: UploadFile = File(..., description="Data file; name must match the dataset's fileNameRegex"),
    overwrite: bool = Query(False, description="Replace the file if it already exists"),
    ds: Dataset = Depends(pushable_dataset),
):
    """Multipart upload (field name "file"). The file name must match the dataset's fileNameRegex.
    Existing files are only replaced with ?overwrite=true. ERDDAP reloads the dataset within seconds."""
    name = _check_filename(ds, file.filename or "")
    ds.file_dir.mkdir(parents=True, exist_ok=True)
    target = ds.file_dir / name
    existed = target.exists()
    if existed and not overwrite:
        raise HTTPException(409, f"'{name}' already exists; use ?overwrite=true to replace it")

    # Stream to a hidden temp file in the same directory, then rename atomically,
    # so ERDDAP never reads a partial upload.
    fd, tmp = tempfile.mkstemp(dir=ds.file_dir, prefix=".upload_")
    size = 0
    try:
        with os.fdopen(fd, "wb") as out:
            while chunk := file.file.read(1024 * 1024):
                size += len(chunk)
                if size > MAX_UPLOAD_BYTES:
                    raise HTTPException(413, f"File larger than {MAX_UPLOAD_BYTES // 1024 // 1024} MB")
                out.write(chunk)
        if size == 0:
            raise HTTPException(400, "Empty file")
        os.chmod(tmp, 0o644)
        os.replace(tmp, target)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise

    return {
        "datasetID": ds.dataset_id,
        "file": _file_info(target),
        "replaced": existed,
        "reload_requested": _request_reload(ds.dataset_id),
    }


@app.delete("/api/datasets/{dataset_id}/files/{filename}", tags=["files"], summary="Delete a data file")
def delete_file(filename: str, ds: Dataset = Depends(pushable_dataset)):
    """Removes the file; ERDDAP drops its data on the next reload (triggered automatically)."""
    name = _check_filename(ds, filename)
    target = ds.file_dir / name
    if not target.is_file():
        raise HTTPException(404, f"'{name}' not found")
    target.unlink()
    return {"datasetID": ds.dataset_id, "deleted": name, "reload_requested": _request_reload(ds.dataset_id)}


@app.post("/api/datasets/{dataset_id}/reload", tags=["datasets"], summary="Force ERDDAP to reload a dataset")
def reload_dataset(ds: Dataset = Depends(pushable_dataset)):
    """Sets the dataset's ERDDAP reload flag, e.g. after changing files by other means."""
    if not _request_reload(ds.dataset_id):
        raise HTTPException(500, "Could not write ERDDAP flag file")
    return {"datasetID": ds.dataset_id, "reload_requested": True}
