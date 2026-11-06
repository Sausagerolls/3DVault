"""Lets a desktop slicer send prints to 3DVault as if each printer were an OctoPrint server.

Slicers ask for a host and an API key. The host is <server>/print-host/<machine id> and the key
is an app token from Settings. "Upload" adds the file to the library, and "Upload and Print" also
puts it in that printer's queue. Only the calls slicers make are provided.
"""

import hashlib
import shutil
import tempfile
import zipfile
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session
from starlette.datastructures import UploadFile

from .api_print import JobIn, _file_print_info, _machine, create_job
from .auth import current_user
from .config import settings
from .db import get_db
from .drivers import DRIVERS
from .formats import is_slicer_project
from .importer import commit_batch, new_batch, stage_file
from .models import File, Model, User
from .services import add_file, refresh_model

router = APIRouter(prefix="/print-host/{machine_id}/api", tags=["print host"])

ACCEPTED = (".gcode.3mf", ".gcode", ".bgcode", ".3mf", ".gco", ".g")
# Slicers only accept a server that calls itself OctoPrint.
VERSION = {"api": "0.1", "server": "1.10.0", "text": "OctoPrint 1.10.0 (3DVault)"}


@router.get("/version")
def version(machine_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    _machine(db, machine_id)
    return VERSION


@router.get("/server")
def server(machine_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    _machine(db, machine_id)
    return {"version": VERSION["server"], "safemode": None}


def wrap_gcode(gcode: Path, out: Path) -> None:
    """A .gcode.3mf holding plain G-code as its first plate, for printers that only take those."""
    digest = hashlib.md5()
    with open(gcode, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", (
            '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>'
            '<Default Extension="gcode" ContentType="text/x.gcode"/></Types>'))
        z.writestr("_rels/.rels", (
            '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>'))
        z.writestr("3D/3dmodel.model", (
            '<?xml version="1.0" encoding="UTF-8"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">'
            "<resources/><build/></model>"))
        z.write(gcode, "Metadata/plate_1.gcode")
        z.writestr("Metadata/plate_1.gcode.md5", digest.hexdigest().upper())


def _is_sliced_project(path: Path) -> bool:
    try:
        with zipfile.ZipFile(path) as z:
            return any(n.startswith("Metadata/plate_") and n.endswith(".gcode") for n in z.namelist())
    except zipfile.BadZipFile:
        return False


def _store(db: Session, tmp: Path, filename: str, stem: str, user: User) -> File:
    """Add to this person's model of the same name, so re-slicing doesn't fill the library."""
    model = (
        db.query(Model)
        .filter(Model.name == stem, Model.uploader_id == user.id, Model.deleted_at.is_(None))
        .order_by(Model.id.desc())
        .first()
    )
    if model is not None:
        f = add_file(db, model, tmp, f"sliced/{filename}", user)
        refresh_model(db, model)
        db.commit()
        return f
    batch = new_batch(db, user, "slicer")
    entries = stage_file(db, batch, tmp, filename)
    if not entries:
        raise HTTPException(415, "3DVault can't store this file")
    model = commit_batch(db, batch, [{"name": stem, "file_ids": [e["id"] for e in entries]}], user)[0]
    return model.files[0]


async def _receive(db: Session, machine_id: int, request: Request, user: User, queue: bool) -> tuple[File, dict | None, list]:
    """Store an uploaded G-code or sliced 3MF, and queue it on this printer if asked."""
    machine = _machine(db, machine_id)
    form = await request.form()
    up = form.get("file")
    if not isinstance(up, UploadFile) or not up.filename:
        raise HTTPException(400, "No file in the upload")
    filename = Path(up.filename.replace("\\", "/")).name
    lower = filename.lower()
    suffix = next((s for s in ACCEPTED if lower.endswith(s)), None)
    if suffix is None:
        raise HTTPException(415, "Send G-code or a sliced 3MF")
    stem = filename[: -len(suffix)] or filename

    tmp = Path(tempfile.mkstemp(dir=settings.staging_dir)[1])
    with open(tmp, "wb") as out:
        shutil.copyfileobj(up.file, out, 1024 * 1024)

    driver = DRIVERS.get(machine.kind)
    # Bambu printers only take a .gcode.3mf, and some slicers send them plain G-code.
    if suffix in (".gcode", ".gco", ".g") and driver and "gcode" not in driver.formats and "gcode3mf" in driver.formats:
        wrapped = Path(tempfile.mkstemp(dir=settings.staging_dir)[1])
        wrap_gcode(tmp, wrapped)
        tmp.unlink(missing_ok=True)
        tmp, filename = wrapped, f"{stem}.gcode.3mf"
    sliced = filename.lower().endswith(".3mf") and _is_sliced_project(tmp)
    if filename.lower().endswith(".3mf") and not sliced and queue:
        tmp.unlink(missing_ok=True)
        raise HTTPException(400, "This 3MF isn't sliced yet. Slice it first, then send it.")

    f = _store(db, tmp, filename, stem, user)
    if not queue:
        return f, None, []
    plates = _file_print_info(db, f).get("plates") or []
    indexes = [p["index"] for p in plates]
    try:
        wanted = int(form.get("plate") or 0)
    except ValueError:
        wanted = 0
    plate = wanted if wanted in indexes else (indexes[0] if indexes else 1)
    try:
        job = create_job(JobIn(file_id=f.id, machine_id=machine.id, plate=plate), db, user)
    except HTTPException as e:
        raise HTTPException(e.status_code, f"Saved to your library, but not queued: {e.detail}") from e
    return f, job, plates


@router.post("/files/local")
async def upload(machine_id: int, request: Request, db: Session = Depends(get_db), user: User = Depends(current_user)):
    form = await request.form()
    queue = str(form.get("print", "")).lower() == "true"
    f, job, _ = await _receive(db, machine_id, request, user, queue)
    name = Path(f.rel_path).name
    body: dict = {"files": {"local": {"name": name, "origin": "local", "path": f.rel_path}}, "done": True}
    if job:
        body["vault_job_id"] = job["id"]
    return JSONResponse(body, status_code=201)


# The apps and web page use this to put a file straight into a printer's queue.
queue_router = APIRouter(prefix="/api/v1", tags=["printing"])


@queue_router.post("/machines/{machine_id}/queue-file", status_code=201)
async def queue_file(machine_id: int, request: Request, db: Session = Depends(get_db), user: User = Depends(current_user)):
    f, job, plates = await _receive(db, machine_id, request, user, True)
    return {"file_id": f.id, "model_id": f.model_id, "job": job, "plates": len(plates)}
