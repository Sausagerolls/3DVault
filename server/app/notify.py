"""Tells the person who sent a print how it is going: Live Activity updates while it runs,
and a notification when it finishes or fails. Sends happen on a background thread."""

import logging
import time
from concurrent.futures import ThreadPoolExecutor

from . import apns
from .db import session_scope
from .models import LiveActivity, PrintJob, PushDevice

log = logging.getLogger("vault.notify")

ACTIVITY_TOPIC = f"{apns.BUNDLE_ID}.push-type.liveactivity"
# Progress updates go out at most this often per job, unless the state changes.
UPDATE_SECONDS = 30

_pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="push")
_last: dict[int, tuple[float, str, float]] = {}  # job id -> (time, state, progress)


def content_state(job: PrintJob) -> dict:
    """Must match PrintActivityAttributes.ContentState in the iOS app."""
    return {
        "state": job.state,
        "progress": round(job.progress or 0, 1),
        "remainingS": job.remaining_s,
        "layer": job.layer,
        "totalLayers": job.total_layers,
        "error": job.error[:120],
    }


def attributes(job: PrintJob) -> dict:
    return {"jobId": job.id, "modelId": job.model_id or 0, "modelName": job.model_name, "printerName": job.machine.name if job.machine else ""}


def snapshot(job: PrintJob) -> dict:
    """What the push needs, taken now: the sending thread may run before the job is committed."""
    return {
        "id": job.id, "user_id": job.user_id, "model_id": job.model_id, "machine_id": job.machine_id,
        "state": job.state, "error": job.error, "model_name": job.model_name,
        "content": content_state(job), "attributes": attributes(job),
    }


def started(job: PrintJob) -> None:
    _pool.submit(_safe, _started, snapshot(job))


def progress(job: PrintJob) -> None:
    """Called every poll while a job runs; throttled here."""
    now = time.monotonic()
    last = _last.get(job.id)
    if last and last[1] == job.state and (now - last[0] < UPDATE_SECONDS or abs(job.progress - last[2]) < 1):
        return
    _last[job.id] = (now, job.state, job.progress)
    _pool.submit(_safe, _update, snapshot(job), "update")


def ended(job: PrintJob) -> None:
    _last.pop(job.id, None)
    _pool.submit(_safe, _ended, snapshot(job))


def _safe(fn, *args) -> None:
    if not apns.configured():
        return
    try:
        fn(*args)
    except Exception:
        log.exception("push %s failed", fn.__name__)


def _started(job: dict) -> None:
    with session_scope() as db:
        if not job["user_id"]:
            return
        if db.query(LiveActivity).filter(LiveActivity.job_id == job["id"]).count():
            _update_db(db, job, "update")
            return
        # Push-to-start: the device starts the Live Activity itself, then sends us its token.
        payload = {"aps": {
            "timestamp": int(time.time()), "event": "start",
            "content-state": job["content"],
            "attributes-type": "PrintActivityAttributes",
            "attributes": job["attributes"],
            "alert": {"title": "Printing", "body": f"{job['model_name']} started on {job['attributes']['printerName']}"},
        }}
        for d in db.query(PushDevice).filter(PushDevice.user_id == job["user_id"], PushDevice.start_token != ""):
            if apns.sender.send(d.start_token, d.environment, payload, "liveactivity", ACTIVITY_TOPIC) == 410:
                d.start_token = ""


def _update(job: dict, event: str) -> None:
    with session_scope() as db:
        _update_db(db, job, event)


def _update_db(db, job: dict, event: str) -> None:
    now = int(time.time())
    aps = {"timestamp": now, "event": event, "content-state": job["content"]}
    if event == "end":
        aps["dismissal-date"] = now + 4 * 3600
    # Routine progress uses low priority, which doesn't count against Apple's update budget.
    priority = 10 if event == "end" or job["state"] != "printing" else 5
    for a in db.query(LiveActivity).filter(LiveActivity.job_id == job["id"]):
        code = apns.sender.send(a.token, a.environment, {"aps": aps}, "liveactivity", ACTIVITY_TOPIC, priority)
        if code == 410 or event == "end":
            db.delete(a)


def _ended(job: dict) -> None:
    with session_scope() as db:
        _update_db(db, job, "end")
        if job["state"] not in ("finished", "failed") or not job["user_id"]:
            return
        printer = job["attributes"]["printerName"] or "the printer"
        if job["state"] == "finished":
            alert = {"title": "Print finished", "body": f"{job['model_name']} is done on {printer}. Clear the bed for the next print."}
        else:
            alert = {"title": "Print failed", "body": f"{job['model_name']} stopped on {printer}. {job['error']}".strip()}
        payload = {"aps": {"alert": alert, "sound": "default", "thread-id": f"printer-{job['machine_id']}"},
                   "modelId": job["model_id"], "jobId": job["id"]}
        for d in db.query(PushDevice).filter(PushDevice.user_id == job["user_id"]):
            if apns.sender.send(d.token, d.environment, payload, collapse_id=f"job-{job['id']}") == 410:
                db.delete(d)
