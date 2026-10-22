"""Printers 3DVault can send to, their live status, and print jobs."""

import asyncio

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel
from sqlalchemy.orm import Session

from .auth import current_user, require_admin
from .db import get_db
from .drivers import DRIVERS, DriverError
from .formats import print_format, sliced_3mf_info
from .library import file_path
from .models import File, Machine, Printer, PrintJob, User
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
        "has_camera": bool(driver and driver.has_camera),
        "formats": sorted(driver.formats) if driver else [],
        "status": s.as_dict() if s else {"state": "offline", "message": "Disabled"},
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


@router.get("/machines")
def list_machines(db: Session = Depends(get_db), user: User = Depends(current_user)):
    return [_machine_out(db, m) for m in db.query(Machine).order_by(Machine.name)]


@router.get("/machines/{machine_id}")
def get_machine(machine_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    return _machine_out(db, _machine(db, machine_id))


@router.post("/machines")
def create_machine(body: MachineIn, db: Session = Depends(get_db), admin: User = Depends(require_admin)):
    _check(db, body)
    m = Machine(
        name=body.name.strip(), kind=body.kind, host=body.host.strip(), serial=body.serial.strip(),
        secret=seal(body.secret or ""), printer_id=body.printer_id, enabled=body.enabled,
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
    m.printer_id, m.enabled = body.printer_id, body.enabled
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
    limit: int = 50,
    db: Session = Depends(get_db),
    user: User = Depends(current_user),
):
    q = db.query(PrintJob)
    if machine_id is not None:
        q = q.filter(PrintJob.machine_id == machine_id)
    if model_id is not None:
        q = q.filter(PrintJob.model_id == model_id)
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
