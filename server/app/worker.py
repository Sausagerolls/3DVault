"""Background worker: file processing queue, inbox watcher, trash purge, library rescan."""

import logging
import os
import shutil
import subprocess
import sys
import time
from datetime import timedelta
from pathlib import Path

from .config import settings
from .db import create_schema, init_engine, session_scope
from .library import SIDECAR, file_path, purge_files, read_sidecar, thumb_path
from .models import File, Job, Model, Setting, UploadBatch, User, utcnow
from .seed import seed_defaults

log = logging.getLogger("vault.worker")
FILE_TIMEOUT = int(os.environ.get("VAULT_FILE_TIMEOUT", "900"))
DUPLICATES_DIR = "_duplicates"


def claim_job() -> tuple[int, str, dict] | None:
    with session_scope() as db:
        job = db.query(Job).filter(Job.status == "queued").order_by(Job.id).first()
        if job is None:
            return None
        job.status = "running"
        job.attempts += 1
        return job.id, job.kind, dict(job.payload)


def finish_job(job_id: int, error: str = "") -> None:
    with session_scope() as db:
        job = db.get(Job, job_id)
        if job is None:
            return
        job.status = "error" if error else "done"
        job.error = error[:4000]
        job.finished_at = utcnow()


def run_job(kind: str, payload: dict) -> None:
    from . import services

    if kind == "process_file":
        fid = payload["file_id"]
        try:
            subprocess.run(
                [sys.executable, "-m", "app.tasks", "process_file", str(fid)],
                check=True,
                timeout=FILE_TIMEOUT,
                capture_output=True,
                cwd=Path(__file__).parent.parent,
            )
            err = ""
        except subprocess.TimeoutExpired:
            err = f"Processing timed out after {FILE_TIMEOUT}s"
        except subprocess.CalledProcessError as e:
            if e.returncode in (-9, 137):
                err = "Ran out of memory building the 3D preview"
            else:
                last = (e.stderr or b"").decode(errors="replace").strip().splitlines()[-1:]
                err = f"Processing failed: {last[0] if last else f'exit code {e.returncode}'}"
        with session_scope() as db:
            f = db.get(File, fid)
            if f is None:
                return
            if err:
                f.status, f.error = "error", err
                # Embedded slicer/G-code thumbnails are cheap to extract, so still give it a cover.
                if not f.has_thumb:
                    try:
                        from .formats import embedded_thumbnail
                        from .mesh import image_thumbnail

                        data = embedded_thumbnail(file_path(f))
                        if data:
                            image_thumbnail(data, thumb_path(f.id))
                            f.has_thumb = True
                            f.status = "ready"
                    except Exception:
                        pass
            services.refresh_model(db, f.model)
        if err:
            raise RuntimeError(err)
    elif kind == "import_url":
        from .urlmeta import fetch

        with session_scope() as db:
            model = db.get(Model, payload["model_id"])
            token = (db.get(Setting, "thingiverse_token") or Setting(value="")).value
            if model is None:
                return
            meta = fetch(payload["url"], token)
            services.apply_url_meta(db, model, meta, overwrite=payload.get("overwrite", False))
    elif kind == "apply_rules":
        with session_scope() as db:
            q = db.query(Model).filter(Model.deleted_at.is_(None))
            if payload.get("untriaged_only", True):
                q = q.filter(Model.untriaged.is_(True))
            for model in q:
                services.apply_rules(db, model)
                services.refresh_model(db, model)
    elif kind == "rescan":
        rescan_library()
    else:
        raise ValueError(f"Unknown job kind {kind}")


# ---------------------------------------------------------------- periodic


def rescan_library() -> None:
    """Sync DB with disk: new folders become models, new/removed files are indexed."""
    from . import services

    with session_scope() as db:
        by_slug = {m.slug: m for m in db.query(Model).filter(Model.deleted_at.is_(None))}
        for d in sorted(settings.library_dir.iterdir()):
            if not d.is_dir() or d.name.startswith("."):
                continue
            model = by_slug.get(d.name)
            if model is None:
                side = read_sidecar(d)
                model = Model(name=side.get("name") or d.name, slug=d.name)
                db.add(model)
                db.flush()
                for field in ("description", "source_url", "author", "license", "print_notes"):
                    if side.get(field):
                        setattr(model, field, side[field])
                if side.get("category"):
                    cat = services.get_or_create_category_path(db, side["category"])
                    model.category_id = cat.id if cat else None
                    model.untriaged = False
                model.tags = services.get_or_create_tags(db, side.get("tags") or [])
            known = {f.rel_path: f for f in model.files}
            on_disk = set()
            for p in d.rglob("*"):
                if p.is_file() and p.name != SIDECAR and not p.name.startswith("."):
                    rel = p.relative_to(d).as_posix()
                    on_disk.add(rel)
                    if rel not in known:
                        services.register_in_place(db, model, rel)
            for rel, f in known.items():
                if rel not in on_disk:
                    db.delete(f)
            db.flush()
            db.refresh(model)
            services.refresh_model(db, model)


def purge_trash() -> None:
    cutoff = utcnow() - timedelta(days=settings.trash_days)
    with session_scope() as db:
        for model in db.query(Model).filter(Model.deleted_at.isnot(None), Model.deleted_at < cutoff):
            purge_files(model)
            db.delete(model)
        stale = utcnow() - timedelta(days=2)
        for batch in db.query(UploadBatch).filter(UploadBatch.created_at < stale):
            shutil.rmtree(settings.staging_dir / batch.id, ignore_errors=True)
            db.delete(batch)
        db.query(Job).filter(Job.status == "done", Job.finished_at < utcnow() - timedelta(days=1)).delete()


_inbox_seen: dict[str, tuple[int, float]] = {}


def _tree_signature(p: Path) -> tuple[int, float]:
    if p.is_file():
        st = p.stat()
        return st.st_size, st.st_mtime
    total, newest = 0, 0.0
    for c in p.rglob("*"):
        if c.is_file():
            st = c.stat()
            total += st.st_size
            newest = max(newest, st.st_mtime)
    return total, newest


def scan_inbox() -> None:
    """Import top-level inbox entries once they have stopped changing between two polls."""
    from .importer import commit_batch, new_batch, propose_groups, stage_file

    inbox = settings.inbox_dir
    if not inbox.is_dir():
        return
    ready = []
    for entry in sorted(inbox.iterdir()):
        if entry.name.startswith((".", "@", "_")):  # hidden, Synology @eaDir, _duplicates
            continue
        sig = _tree_signature(entry)
        if sig[0] == 0:
            continue
        if _inbox_seen.get(entry.name) == sig and time.time() - sig[1] > 20:
            ready.append(entry)
        else:
            _inbox_seen[entry.name] = sig
    if not ready:
        return
    with session_scope() as db:
        owner = db.query(User).filter(User.role == "admin").order_by(User.id).first()
        if owner is None:
            return
        batch = new_batch(db, owner, source="inbox")
        for entry in ready:
            files = [entry] if entry.is_file() else sorted(c for c in entry.rglob("*") if c.is_file())
            for f in files:
                rel = f.relative_to(inbox).as_posix()
                tmp = settings.staging_dir / batch.id / f".in-{os.urandom(6).hex()}"
                shutil.move(str(f), tmp)
                stage_file(db, batch, tmp, rel)
            if entry.is_dir():
                shutil.rmtree(entry, ignore_errors=True)
            _inbox_seen.pop(entry.name, None)
        # Exact duplicates of files already in the library are set aside, never deleted.
        dups = {e["id"]: e for e in batch.files if e.get("dup_model_id")}
        for e in dups.values():
            dest = inbox / DUPLICATES_DIR / e["path"]
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(settings.staging_dir / batch.id / e["id"]), dest)
        groups = propose_groups([e for e in batch.files if e["id"] not in dups])
        created = commit_batch(db, batch, groups, owner)
        log.info("Inbox imported %d model(s), %d duplicate file(s) moved to %s", len(created), len(dups), DUPLICATES_DIR)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s worker %(levelname)s %(message)s")
    try:
        os.nice(10)
    except OSError:
        pass
    init_engine()
    create_schema()
    seed_defaults()
    with session_scope() as db:
        db.query(Job).filter(Job.status == "running").update({"status": "queued"})
    last_inbox = last_purge = 0.0
    log.info("Worker started")
    while True:
        now = time.time()
        if now - last_inbox > settings.inbox_poll_seconds:
            last_inbox = now
            try:
                scan_inbox()
            except Exception:
                log.exception("Inbox scan failed")
        if now - last_purge > 3600:
            last_purge = now
            try:
                purge_trash()
            except Exception:
                log.exception("Trash purge failed")
        job = claim_job()
        if job is None:
            time.sleep(2)
            continue
        job_id, kind, payload = job
        try:
            run_job(kind, payload)
            finish_job(job_id)
        except Exception as e:
            log.warning("Job %s %s failed: %s", job_id, kind, e)
            finish_job(job_id, str(e))


if __name__ == "__main__":
    main()
