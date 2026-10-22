"""Print manager: keeps a driver per printer, tracks live status and runs the per-printer queue.

Runs inside the API process on background threads, because API calls such as pause and
camera snapshots need the same live connections.
"""

import logging
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .db import session_scope
from .drivers import DRIVERS, Driver, DriverError, MachineConfig, PrintRequest, Status
from .library import file_path
from .models import File, Machine, PrintJob, UserModel, utcnow
from .secretbox import unseal

log = logging.getLogger("vault.print")

POLL_SECONDS = 2.0
ACTIVE = ("uploading", "printing", "paused")
ENDED = ("finished", "failed", "cancelled")


class PrintManager:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._drivers: dict[int, tuple[Driver, tuple]] = {}
        self._status: dict[int, Status] = {}
        self._sending: set[int] = set()
        # Jobs the printer has been seen running. Until then an idle or finished printer is the
        # state before our job started, not the end of it.
        self._seen: set[int] = set()
        self._wake = threading.Event()
        self._pool = ThreadPoolExecutor(max_workers=8, thread_name_prefix="printer")
        self._thread: threading.Thread | None = None

    # ---------------------------------------------------------------- lifecycle

    def start(self) -> None:
        if self._thread:
            return
        with session_scope() as db:
            self._seen.update(j.id for j in db.query(PrintJob).filter(PrintJob.state.in_(("printing", "paused"))))
            # An upload interrupted by a restart never reached the printer.
            for j in db.query(PrintJob).filter(PrintJob.state == "uploading"):
                j.state, j.error, j.finished_at = "failed", "Server restarted while sending the file", utcnow()
        self._thread = threading.Thread(target=self._run, name="print-manager", daemon=True)
        self._thread.start()

    def wake(self) -> None:
        """Run the loop now, for example after a job is queued or the bed is cleared."""
        self._wake.set()

    def _run(self) -> None:
        while True:
            try:
                self._cycle()
            except Exception:
                log.exception("print manager cycle failed")
            self._wake.wait(POLL_SECONDS)
            self._wake.clear()

    # ---------------------------------------------------------------- drivers

    def _sync_drivers(self, machines: list[Machine]) -> None:
        wanted = {}
        for m in machines:
            if m.enabled and m.kind in DRIVERS:
                wanted[m.id] = (m.kind, m.host, m.serial, m.secret, m.name)
        with self._lock:
            for mid in list(self._drivers):
                if self._drivers[mid][1] != wanted.get(mid):
                    driver = self._drivers.pop(mid)[0]
                    self._status.pop(mid, None)
                    self._pool.submit(driver.stop)
            for mid, sig in wanted.items():
                if mid in self._drivers:
                    continue
                kind, host, serial, secret, name = sig
                driver = DRIVERS[kind](MachineConfig(mid, name, kind, host, serial, unseal(secret)))
                self._drivers[mid] = (driver, sig)
                self._pool.submit(self._start_driver, mid, driver)

    def _start_driver(self, mid: int, driver: Driver) -> None:
        try:
            driver.start()
        except Exception as e:
            log.warning("printer %s failed to connect: %s", mid, e)

    def driver(self, machine_id: int) -> Driver:
        with self._lock:
            entry = self._drivers.get(machine_id)
        if entry is None:
            raise DriverError("Printer is disabled or not connected yet")
        return entry[0]

    def status(self, machine_id: int) -> Status:
        with self._lock:
            s = self._status.get(machine_id)
            connected = machine_id in self._drivers
        if s is None:
            return Status(state="offline", message="Connecting…" if connected else "Disabled")
        return s

    def _poll(self, mid: int, driver: Driver) -> None:
        try:
            s = driver.status()
        except Exception as e:
            s = Status(state="offline", message=str(e) or e.__class__.__name__)
        with self._lock:
            if mid in self._drivers and self._drivers[mid][0] is driver:
                self._status[mid] = s

    # ---------------------------------------------------------------- loop

    def _cycle(self) -> None:
        with session_scope() as db:
            machines = db.query(Machine).all()
            self._sync_drivers(machines)
        with self._lock:
            drivers = {mid: d for mid, (d, _) in self._drivers.items()}
        futures = [self._pool.submit(self._poll, mid, d) for mid, d in drivers.items()]
        for f in futures:
            try:
                f.result(timeout=15)
            except Exception:
                pass
        with session_scope() as db:
            for m in db.query(Machine).filter(Machine.enabled.is_(True)):
                if m.id in drivers:
                    self._reconcile(db, m, self.status(m.id))

    def _reconcile(self, db, machine: Machine, s: Status) -> None:
        active = (
            db.query(PrintJob)
            .filter(PrintJob.machine_id == machine.id, PrintJob.state.in_(ACTIVE))
            .order_by(PrintJob.id)
            .first()
        )
        if active and active.state in ("printing", "paused"):
            if s.state in ("preparing", "printing", "paused"):
                self._seen.add(active.id)
                active.state = "paused" if s.state == "paused" else "printing"
                active.progress = s.progress
                active.layer, active.total_layers, active.remaining_s = s.layer, s.total_layers, s.remaining_s
            elif active.id in self._seen and s.state in ("finished", "failed", "idle"):
                outcome = {"finished": "finished", "failed": "failed"}.get(s.state, "cancelled")
                if outcome == "finished":
                    active.progress = 100
                self.end_job(db, active, outcome, s.message if outcome == "failed" else "")
            return
        if active is None and not machine.needs_clear and s.state in ("idle", "finished"):
            with self._lock:
                if machine.id in self._sending:
                    return
            nxt = (
                db.query(PrintJob)
                .filter(PrintJob.machine_id == machine.id, PrintJob.state == "queued")
                .order_by(PrintJob.id)
                .first()
            )
            if nxt:
                nxt.state, nxt.started_at, nxt.error = "uploading", utcnow(), ""
                db.flush()
                with self._lock:
                    self._sending.add(machine.id)
                self._pool.submit(self._send, machine.id, nxt.id)

    def end_job(self, db, job: PrintJob, outcome: str, error: str = "") -> None:
        job.state, job.finished_at, job.error = outcome, utcnow(), error
        if outcome in ("finished", "failed"):
            job.remaining_s = 0
        self._seen.discard(job.id)
        machine = db.get(Machine, job.machine_id)
        if machine and outcome in ("finished", "failed", "cancelled") and job.started_at:
            machine.needs_clear = True
        # A finished or failed print sets the sender's print status on the model.
        if outcome in ("finished", "failed") and job.user_id and job.model_id:
            um = db.get(UserModel, (job.user_id, job.model_id))
            if um is None:
                um = UserModel(user_id=job.user_id, model_id=job.model_id)
                db.add(um)
            um.status = "printed" if outcome == "finished" else "failed"
        log.info("print job %s on printer %s %s", job.id, job.machine_id, outcome)

    def _send(self, machine_id: int, job_id: int) -> None:
        error = ""
        try:
            with session_scope() as db:
                job = db.get(PrintJob, job_id)
                f = db.get(File, job.file_id) if job and job.file_id else None
                if f is None:
                    raise DriverError("The file was deleted")
                path = file_path(f)
                req = PrintRequest(
                    path=path,
                    remote_name=remote_name(f.rel_path),
                    plate=job.plate,
                    ams_mapping=list(job.options.get("ams_mapping") or []),
                    options=dict(job.options),
                )
            self.driver(machine_id).send(req)
        except DriverError as e:
            error = str(e)
        except Exception as e:
            log.exception("sending job %s failed", job_id)
            error = f"Could not send to the printer: {e}"
        finally:
            with self._lock:
                self._sending.discard(machine_id)
        with session_scope() as db:
            job = db.get(PrintJob, job_id)
            if job is None or job.state != "uploading":
                return
            if error:
                job.state, job.error, job.finished_at = "failed", error, utcnow()
                job.started_at = None  # never reached the bed, so it doesn't need clearing
            else:
                job.state = "printing"
        self.wake()


def remote_name(rel_path: str) -> str:
    """File name to store on the printer: the base name with characters printers dislike removed."""
    name = Path(rel_path).name
    safe = "".join(c if c.isalnum() or c in "._-" else "_" for c in name)
    return safe or "print.gcode"


manager = PrintManager()
