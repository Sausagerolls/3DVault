"""Printers 3DVault can send to, their live status, and print jobs."""

import asyncio
import math
import re

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse, Response
from starlette.datastructures import UploadFile
from pydantic import BaseModel
from sqlalchemy import or_
from sqlalchemy.orm import Session

from .auth import current_user, require_admin
from .db import get_db
from .drivers import DRIVERS, DriverError, Status
from .formats import print_format, sliced_3mf_info
from .library import file_path
from . import prepare, services, slicer, toolpaths
from .mesh import MeshError
from .models import File, Machine, Model, Printer, PrintJob, SliceTask, User
from .printing import ACTIVE, manager
from .secretbox import seal

router = APIRouter(prefix="/api/v1", tags=["printing"])


# ---------------------------------------------------------------- printers


class MachineIn(BaseModel):
    name: str
    kind: str
    host: str = ""
    serial: str = ""
    secret: str | None = None  # None keeps the stored value on update
    printer_id: int | None = None
    enabled: bool = True
    slicer_printer: str = ""
    installed_filament: str = ""
    installed_colour: str = ""


def _machine_out(db: Session, m: Machine) -> dict:
    s = manager.status(m.id) if m.enabled else None
    active = (
        db.query(PrintJob).filter(PrintJob.machine_id == m.id, PrintJob.state.in_(ACTIVE)).order_by(PrintJob.id).first()
    )
    queued = db.query(PrintJob).filter(PrintJob.machine_id == m.id, PrintJob.state == "queued").count()
    driver = DRIVERS.get(m.kind)
    return {
        "id": m.id,
        "name": m.name,
        "kind": m.kind,
        "host": m.host,
        "serial": m.serial,
        "has_secret": bool(m.secret),
        "printer_id": m.printer_id,
        "bed": {"x": m.printer.x, "y": m.printer.y, "z": m.printer.z} if m.printer else None,
        "enabled": m.enabled,
        "needs_clear": m.needs_clear,
        "slicer_printer": m.slicer_printer,
        "installed_filament": m.installed_filament,
        "installed_colour": m.installed_colour,
        "has_camera": bool(driver and driver.has_camera),
        "formats": sorted(driver.formats) if driver else [],
        "status": (s or Status(state="offline", message="Disabled")).as_dict(),
        "active_job": _job_out(active) if active else None,
        "queued": queued,
    }


def _check(db: Session, body: MachineIn, machine_id: int | None = None) -> None:
    if body.kind not in DRIVERS:
        raise HTTPException(400, f"Unsupported printer type: {body.kind}")
    if not body.name.strip():
        raise HTTPException(400, "Name is required")
    clash = db.query(Machine).filter(Machine.name == body.name.strip(), Machine.id != (machine_id or -1)).first()
    if clash:
        raise HTTPException(409, "A printer with that name already exists")
    if body.printer_id is not None and db.get(Printer, body.printer_id) is None:
        raise HTTPException(400, "Unknown bed size profile")
    if body.slicer_printer.strip() and slicer.available() and not slicer.profiles.find("machine", body.slicer_printer.strip()):
        raise HTTPException(400, "Unknown slicer printer profile")


@router.get("/machine-kinds")
def machine_kinds(user: User = Depends(current_user)):
    return [
        {
            "kind": d.kind,
            "label": d.label,
            "formats": sorted(d.formats),
            "has_camera": d.has_camera,
            "fields": [{"key": k, "label": label, "secret": secret} for k, label, secret in d.fields],
        }
        for d in DRIVERS.values()
    ]


@router.post("/machines/discover")
async def discover_machines(db: Session = Depends(get_db), admin: User = Depends(require_admin)):
    """Listen for printers announcing themselves on the LAN. Takes about six seconds."""
    from .drivers.bambu import discover

    found = await asyncio.to_thread(discover)
    known = {m.serial for m in db.query(Machine) if m.serial}
    return [{**p, "added": p["serial"] in known} for p in found]


@router.get("/machines")
def list_machines(db: Session = Depends(get_db), user: User = Depends(current_user)):
    return [_machine_out(db, m) for m in db.query(Machine).order_by(Machine.name)]


@router.get("/machines/{machine_id}")
def get_machine(machine_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    return _machine_out(db, _machine(db, machine_id))


def _colour(text: str) -> str:
    text = text.strip()
    if text and not re.fullmatch(r"#[0-9a-fA-F]{6}", text):
        raise HTTPException(400, "Filament colour must look like #RRGGBB")
    return text


@router.post("/machines")
def create_machine(body: MachineIn, db: Session = Depends(get_db), admin: User = Depends(require_admin)):
    _check(db, body)
    m = Machine(
        name=body.name.strip(), kind=body.kind, host=body.host.strip(), serial=body.serial.strip(),
        secret=seal(body.secret or ""), printer_id=body.printer_id, enabled=body.enabled,
        slicer_printer=body.slicer_printer.strip(),
        installed_filament=body.installed_filament.strip(), installed_colour=_colour(body.installed_colour),
    )
    db.add(m)
    db.commit()
    manager.wake()
    return _machine_out(db, m)


@router.patch("/machines/{machine_id}")
def patch_machine(machine_id: int, body: MachineIn, db: Session = Depends(get_db), admin: User = Depends(require_admin)):
    m = _machine(db, machine_id)
    _check(db, body, machine_id)
    m.name, m.kind, m.host, m.serial = body.name.strip(), body.kind, body.host.strip(), body.serial.strip()
    m.printer_id, m.enabled, m.slicer_printer = body.printer_id, body.enabled, body.slicer_printer.strip()
    m.installed_filament, m.installed_colour = body.installed_filament.strip(), _colour(body.installed_colour)
    if body.secret is not None:
        m.secret = seal(body.secret)
    db.commit()
    manager.wake()
    return _machine_out(db, m)


@router.delete("/machines/{machine_id}", status_code=204)
def delete_machine(machine_id: int, db: Session = Depends(get_db), admin: User = Depends(require_admin)):
    db.query(Machine).filter(Machine.id == machine_id).delete()
    db.commit()
    manager.wake()


def _machine(db: Session, machine_id: int) -> Machine:
    m = db.get(Machine, machine_id)
    if m is None:
        raise HTTPException(404)
    return m


async def _command(machine_id: int, action: str) -> None:
    try:
        driver = manager.driver(machine_id)
        await asyncio.to_thread(getattr(driver, action))
    except DriverError as e:
        raise HTTPException(409, str(e))
    manager.wake()


@router.post("/machines/{machine_id}/pause", status_code=204)
async def pause(machine_id: int, user: User = Depends(current_user)):
    await _command(machine_id, "pause")


@router.post("/machines/{machine_id}/resume", status_code=204)
async def resume(machine_id: int, user: User = Depends(current_user)):
    await _command(machine_id, "resume")


@router.post("/machines/{machine_id}/cancel", status_code=204)
async def cancel(machine_id: int, user: User = Depends(current_user)):
    await _command(machine_id, "cancel")


@router.post("/machines/{machine_id}/bed-cleared")
def bed_cleared(machine_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    m = _machine(db, machine_id)
    m.needs_clear = False
    db.commit()
    manager.wake()
    return _machine_out(db, m)


@router.get("/machines/{machine_id}/camera")
async def camera(machine_id: int, user: User = Depends(current_user)):
    try:
        frame = await asyncio.to_thread(manager.driver(machine_id).snapshot)
    except DriverError as e:
        raise HTTPException(409, str(e))
    if not frame:
        raise HTTPException(404, "No camera image")
    return Response(frame, media_type="image/jpeg", headers={"Cache-Control": "no-store"})


# ---------------------------------------------------------------- jobs


def _job_out(j: PrintJob) -> dict:
    return {
        "id": j.id,
        "machine_id": j.machine_id,
        "machine_name": j.machine.name if j.machine else "",
        "model_id": j.model_id,
        "model_name": j.model_name,
        "file_id": j.file_id,
        "file_name": j.file_name,
        "plate": j.plate,
        "user": j.user.display_name if j.user else None,
        "user_id": j.user_id,
        "external": bool((j.options or {}).get("external")),
        "state": j.state,
        "progress": j.progress,
        "layer": j.layer,
        "total_layers": j.total_layers,
        "remaining_s": j.remaining_s,
        "error": j.error,
        "created_at": j.created_at,
        "started_at": j.started_at,
        "finished_at": j.finished_at,
    }


def _file_print_info(db: Session, f: File) -> dict:
    """What the print sheet needs to know about a file."""
    meta = dict(f.meta or {})
    # Files processed before sliced 3MF detection existed: check now and remember.
    if f.ext == "3mf" and "sliced" not in meta and "sliced_checked" not in meta:
        sliced = sliced_3mf_info(file_path(f))
        meta["sliced_checked"] = True
        if sliced:
            meta["sliced"] = sliced
        f.meta = meta
        db.commit()
    fmt = print_format(f.rel_path, meta)
    plates = (meta.get("sliced") or {}).get("plates") or []
    return {
        "file_id": f.id,
        "format": fmt,
        "sliceable": fmt is None and f.ext in SLICEABLE and slicer.available(),
        "plates": plates,
        "print_time": meta.get("print_time"),
        "filament_g": meta.get("filament_g"),
        "filament_type": meta.get("filament_type"),
        "printer_model": meta.get("printer_model"),
    }


@router.get("/files/{file_id}/print-info")
def print_info(file_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    f = db.get(File, file_id)
    if f is None:
        raise HTTPException(404)
    info = _file_print_info(db, f)
    info["machines"] = [
        {"id": m.id, "name": m.name, "compatible": info["format"] in DRIVERS[m.kind].formats}
        for m in db.query(Machine).filter(Machine.enabled.is_(True)).order_by(Machine.name)
        if m.kind in DRIVERS
    ]
    return info


class JobIn(BaseModel):
    file_id: int
    machine_id: int
    plate: int = 1
    ams_mapping: list[int] = []
    options: dict = {}


@router.post("/jobs")
def create_job(body: JobIn, db: Session = Depends(get_db), user: User = Depends(current_user)):
    f = db.get(File, body.file_id)
    if f is None or f.model.deleted_at is not None:
        raise HTTPException(404, "File not found")
    m = _machine(db, body.machine_id)
    if not m.enabled or m.kind not in DRIVERS:
        raise HTTPException(409, "Printer is disabled")
    info = _file_print_info(db, f)
    if info["format"] is None:
        raise HTTPException(400, "This file needs slicing first")
    if info["format"] not in DRIVERS[m.kind].formats:
        raise HTTPException(400, f"{m.name} can't print {info['format']} files")
    if info["plates"] and body.plate not in [p["index"] for p in info["plates"]]:
        raise HTTPException(400, "That plate isn't sliced in this file")
    job = PrintJob(
        machine_id=m.id, model_id=f.model_id, file_id=f.id, user_id=user.id,
        model_name=f.model.name, file_name=f.rel_path, plate=body.plate,
        options={**body.options, "ams_mapping": body.ams_mapping},
    )
    db.add(job)
    db.commit()
    manager.wake()
    return _job_out(job)


@router.get("/jobs")
def list_jobs(
    machine_id: int | None = None,
    model_id: int | None = None,
    active: bool = False,
    mine: bool = False,
    external: bool = False,
    limit: int = 50,
    db: Session = Depends(get_db),
    user: User = Depends(current_user),
):
    q = db.query(PrintJob)
    if machine_id is not None:
        q = q.filter(PrintJob.machine_id == machine_id)
    if model_id is not None:
        q = q.filter(PrintJob.model_id == model_id)
    if mine:
        # external=true also includes prints started outside 3DVault, which belong to no one.
        q = q.filter(or_(PrintJob.user_id == user.id, PrintJob.user_id.is_(None)) if external else PrintJob.user_id == user.id)
    if active:
        q = q.filter(PrintJob.state.in_(("queued", *ACTIVE)))
        return [_job_out(j) for j in q.order_by(PrintJob.id).limit(limit)]
    return [_job_out(j) for j in q.order_by(PrintJob.id.desc()).limit(min(limit, 200))]


@router.get("/jobs/{job_id}")
def get_job(job_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    j = db.get(PrintJob, job_id)
    if j is None:
        raise HTTPException(404)
    return _job_out(j)


@router.post("/jobs/{job_id}/cancel")
async def cancel_job(job_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    j = db.get(PrintJob, job_id)
    if j is None:
        raise HTTPException(404)
    if j.state == "queued":
        manager.end_job(db, j, "cancelled")
    elif j.state in ("printing", "paused"):
        try:
            await asyncio.to_thread(manager.driver(j.machine_id).cancel)
        except DriverError as e:
            raise HTTPException(409, str(e))
        manager.end_job(db, j, "cancelled")
    elif j.state == "uploading":
        raise HTTPException(409, "The file is being sent. Cancel it on the printer once it starts.")
    db.commit()
    manager.wake()
    return _job_out(j)


# ---------------------------------------------------------------- slicing

SLICEABLE = {"stl", "obj", "3mf", "step", "stp", "amf"}
BED_TYPES = ["Cool Plate", "Engineering Plate", "High Temp Plate", "Textured PEI Plate", "Supertack Plate", "Smooth Cool Plate"]


@router.get("/slicer")
def slicer_status(user: User = Depends(current_user)):
    return {"available": slicer.available()}


@router.get("/slicer/printers")
def slicer_printers(q: str = "", limit: int = 50, user: User = Depends(current_user)):
    words = q.lower().split()
    found = [p for p in slicer.profiles.printers() if all(w in p["name"].lower() for w in words)]
    return found[: min(limit, 500)]


@router.get("/slicer/filaments")
def slicer_filaments(printer: str, user: User = Depends(current_user)):
    """Filament profiles for a printer profile, for choosing what's loaded in a printer."""
    try:
        return slicer.profiles.for_printer("filament", printer)
    except ValueError as e:
        raise HTTPException(404, str(e))


@router.get("/slicer/options")
def slicer_options(machine_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    """Process and filament profiles, plate types and defaults for slicing on a printer."""
    m = _machine(db, machine_id)
    if not slicer.available():
        raise HTTPException(409, "Slicing isn't available on this server")
    if not m.slicer_printer:
        raise HTTPException(409, f"{m.name} has no slicer profile yet. An admin can choose one in Settings › Printers.")
    try:
        machine = slicer.profiles.flatten("machine", m.slicer_printer)
    except ValueError as e:
        raise HTTPException(409, str(e))
    model = slicer.profiles.machine_model(m.slicer_printer)
    unsupported = set(str(model.get("not_support_bed_type", "")).split(";")) - {""}
    process = machine.get("default_print_profile", "")
    filament = (machine.get("default_filament_profile") or [""])[0]
    proc = slicer.profiles.for_printer("process", m.slicer_printer)
    filaments = slicer.profiles.for_printer("filament", m.slicer_printer)
    # What's loaded in the printer comes first, unless its profile has since gone.
    if any(f["name"] == m.installed_filament for f in filaments):
        filament = m.installed_filament
    defaults = {}
    if any(p["name"] == process for p in proc):
        flat = slicer.profiles.flatten("process", process)
        defaults = {
            "layer_height": _num(flat.get("layer_height")),
            "sparse_infill_density": _num(str(flat.get("sparse_infill_density", "")).rstrip("%")),
            "wall_loops": _num(flat.get("wall_loops")),
            "enable_support": str(flat.get("enable_support", "0")) == "1",
            "support_type": flat.get("support_type", "normal(auto)"),
            "brim_type": flat.get("brim_type", "auto_brim"),
            "sparse_infill_pattern": flat.get("sparse_infill_pattern", "grid"),
            "top_shell_layers": _num(flat.get("top_shell_layers")),
            "bottom_shell_layers": _num(flat.get("bottom_shell_layers")),
            "support_threshold_angle": _num(flat.get("support_threshold_angle")),
            "support_on_build_plate_only": str(flat.get("support_on_build_plate_only", "0")) == "1",
        }
    return {
        "printer": m.slicer_printer,
        "volume": _build_volume(machine),
        "processes": proc,
        "filaments": filaments,
        "bed_types": [b for b in BED_TYPES if b not in unsupported],
        "default_process": process,
        "default_filament": filament,
        "default_bed_type": model.get("default_bed_type", ""),
        "defaults": defaults,
    }


def _build_volume(machine: dict) -> dict | None:
    """The printable size in mm, from the profile's corner list ("0x0", "180x0", ...)."""
    try:
        corners = [tuple(float(n) for n in str(c).split("x")) for c in machine["printable_area"]]
        return {"x": max(c[0] for c in corners), "y": max(c[1] for c in corners), "z": float(_num(machine.get("printable_height")) or 0)}
    except (KeyError, ValueError, IndexError):
        return None


def _num(v):
    try:
        return float(v[0] if isinstance(v, list) else v)
    except (TypeError, ValueError, IndexError):
        return None


@router.get("/slicer/process-schema")
def slicer_process_schema(user: User = Depends(current_user)):
    """Orca's process settings, by page and group, for the 3D editor."""
    schema = slicer.process_schema()
    if schema is None:
        raise HTTPException(409, "This server's image has no slicer settings list")
    return schema


@router.get("/slicer/process-values")
def slicer_process_values(name: str, user: User = Depends(current_user)):
    if not slicer.profiles.find("process", name):
        raise HTTPException(404, "Unknown process profile")
    return slicer.process_values(name)


@router.post("/slicer/import")
async def import_profiles(request: Request, admin: User = Depends(require_admin)):
    """Import presets exported from OrcaSlicer or Bambu Studio (.json, or a zip / .orca_printer / .orca_filament / .bbscfg bundle)."""
    form = await request.form()
    names = []
    for up in form.getlist("files"):
        if isinstance(up, UploadFile) and up.filename:
            try:
                names += await asyncio.to_thread(slicer.import_profiles, up.filename, await up.read())
            except (ValueError, KeyError) as e:
                raise HTTPException(400, f"{up.filename}: not a slicer preset ({e})")
    if not names:
        raise HTTPException(400, "No printer, process or filament presets found in the upload")
    return {"imported": names}


class SliceIn(BaseModel):
    file_ids: list[int]
    machine_id: int
    process: str
    filaments: list[str] = []
    overrides: dict = {}


def _slice_out(t: SliceTask) -> dict:
    return {
        "id": t.id, "model_id": t.model_id, "machine_id": t.machine_id, "file_ids": t.file_ids,
        "process": t.process_profile, "filaments": t.filament_profiles, "overrides": t.overrides,
        "state": t.state, "error": t.error, "output_file_id": t.output_file_id,
        "created_at": t.created_at, "started_at": t.started_at, "finished_at": t.finished_at,
    }


def _check_layout(layout: list, file_ids: list[int]) -> None:
    """An item from the 3D editor: {file_id, matrix (16 numbers), enforce, block, name}."""
    if not isinstance(layout, list) or not layout or len(layout) > 200:
        raise HTTPException(400, "The plate is empty")
    for item in layout:
        matrix = item.get("matrix") if isinstance(item, dict) else None
        if not isinstance(matrix, list) or len(matrix) != 16 or not all(isinstance(x, (int, float)) and math.isfinite(x) for x in matrix):
            raise HTTPException(400, "Bad position on the plate")
        if item.get("file_id") not in file_ids:
            raise HTTPException(400, "A part on the plate isn't one of the files being sliced")
        for key in ("enforce", "block"):
            runs = item.get(key) or []
            if not isinstance(runs, list) or len(runs) % 2 or not all(isinstance(x, int) and x >= 0 for x in runs):
                raise HTTPException(400, "Bad support painting")


@router.get("/files/{file_id}/editor-mesh")
async def editor_mesh(file_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    """The file's mesh for the 3D editor, as a binary STL."""
    f = db.get(File, file_id)
    if f is None:
        raise HTTPException(404)
    if f.ext not in SLICEABLE or print_format(f.rel_path, f.meta) is not None:
        raise HTTPException(400, "This file can't be placed on a plate")
    try:
        path = await asyncio.to_thread(prepare.editor_mesh_path, file_path(f), f.id)
    except MeshError as e:
        raise HTTPException(422, str(e))
    return FileResponse(path, media_type="model/stl")


@router.post("/slices")
def create_slice(body: SliceIn, db: Session = Depends(get_db), user: User = Depends(current_user)):
    if not slicer.available():
        raise HTTPException(409, "Slicing isn't available on this server")
    m = _machine(db, body.machine_id)
    if not m.slicer_printer:
        raise HTTPException(409, f"{m.name} has no slicer profile yet")
    files = [db.get(File, i) for i in body.file_ids]
    if not files or any(f is None for f in files):
        raise HTTPException(404, "File not found")
    if len({f.model_id for f in files}) != 1 or files[0].model.deleted_at is not None:
        raise HTTPException(400, "Files must belong to one model")
    if any(f.ext not in SLICEABLE for f in files):
        raise HTTPException(400, "Only STL, OBJ, 3MF and STEP files can be sliced")
    if "process_values" in body.overrides:
        try:
            body.overrides = {**body.overrides, "process_values": slicer.clean_process_values(body.overrides["process_values"] or {})}
        except ValueError as e:
            raise HTTPException(400, str(e))
    layout = body.overrides.get("layout")
    if layout is not None:
        _check_layout(layout, body.file_ids)
    elif len(files) > 1 and any(f.ext == "3mf" for f in files):
        raise HTTPException(400, "Slice a 3MF project on its own")
    if not slicer.profiles.find("process", body.process):
        raise HTTPException(400, "Unknown process profile")
    for name in body.filaments:
        if not slicer.profiles.find("filament", name):
            raise HTTPException(400, f"Unknown filament profile: {name}")
    # Without a filament slot chosen, the slice shows the colour loaded in the printer.
    if m.installed_colour and not body.overrides.get("filament_colours"):
        body.overrides = {**body.overrides, "filament_colours": [m.installed_colour]}
    t = SliceTask(
        user_id=user.id, model_id=files[0].model_id, machine_id=m.id, file_ids=body.file_ids,
        printer_profile=m.slicer_printer, process_profile=body.process,
        filament_profiles=body.filaments, overrides=body.overrides,
    )
    db.add(t)
    db.flush()
    services.enqueue(db, "slice", slice_id=t.id)
    db.commit()
    return _slice_out(t)


@router.get("/slices/{slice_id}")
def get_slice(slice_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    t = db.get(SliceTask, slice_id)
    if t is None:
        raise HTTPException(404)
    out = _slice_out(t)
    if t.state == "queued":
        # Position among slices waiting, so the app can say "2 ahead".
        out["ahead"] = db.query(SliceTask).filter(SliceTask.state.in_(("queued", "slicing")), SliceTask.id < t.id).count()
    return out


@router.get("/files/{file_id}/toolpaths")
async def toolpath_summary(file_id: int, plate: int = 1, db: Session = Depends(get_db), user: User = Depends(current_user)):
    data = await _toolpaths(db, file_id, plate)
    return toolpaths.summary(data)


@router.get("/files/{file_id}/toolpaths-data")
async def toolpath_data(file_id: int, plate: int = 1, db: Session = Depends(get_db), user: User = Depends(current_user)):
    """All layers in one binary response. See toolpaths.pack for the format."""
    data = await _toolpaths(db, file_id, plate)
    return Response(toolpaths.pack(data), media_type="application/octet-stream")


@router.get("/files/{file_id}/toolpaths/{index}")
async def toolpath_layer(file_id: int, index: int, plate: int = 1, db: Session = Depends(get_db), user: User = Depends(current_user)):
    data = await _toolpaths(db, file_id, plate)
    try:
        return toolpaths.layer(data, index)
    except IndexError:
        raise HTTPException(404, "No such layer")


async def _toolpaths(db: Session, file_id: int, plate: int) -> dict:
    f = db.get(File, file_id)
    if f is None:
        raise HTTPException(404)
    if print_format(f.rel_path, f.meta) is None and f.ext != "3mf":
        raise HTTPException(400, "Not a sliced file")
    try:
        return await asyncio.to_thread(toolpaths.load, f.id, file_path(f), plate)
    except KeyError:
        raise HTTPException(404, "That plate isn't sliced in this file")


# ---------------------------------------------------------------- notifications


@router.get("/notifier")
def get_notifier(admin: User = Depends(require_admin)):
    from . import notify

    return notify.public_config()


class NotifierIn(BaseModel):
    kind: str = ""  # "" (off) | ntfy | gotify | pushover | discord | webhook
    url: str = ""
    topic: str = ""
    user_key: str = ""
    secret: str | None = None  # token or app key; None keeps the stored one
    events: list[str] = ["finished", "failed"]


@router.put("/notifier")
def set_notifier(body: NotifierIn, db: Session = Depends(get_db), admin: User = Depends(require_admin)):
    from . import notify

    try:
        notify.save_config(body.model_dump())
    except ValueError as e:
        raise HTTPException(400, str(e))
    return notify.public_config()


@router.post("/notifier/test", status_code=204)
async def test_notifier(admin: User = Depends(require_admin)):
    from . import notify

    try:
        await asyncio.to_thread(notify.send, "3DVault test", "Notifications from 3DVault are working.", raise_errors=True)
    except Exception as e:
        raise HTTPException(400, f"Sending failed: {e}")
