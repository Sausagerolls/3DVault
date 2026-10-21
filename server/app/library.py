"""On-disk library layout: /library/<slug>/<files> plus a model.json sidecar."""

import hashlib
import json
import os
import re
import shutil
import unicodedata
from pathlib import Path

from sqlalchemy import text
from sqlalchemy.orm import Session

from .config import settings
from .models import File, Model

SIDECAR = "model.json"


def slugify(name: str) -> str:
    s = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    s = re.sub(r"[^\w\s-]", "", s).strip()
    s = re.sub(r"[\s_-]+", "-", s)
    return s[:120] or "model"


def unique_slug(db: Session, name: str) -> str:
    base = slugify(name)
    slug, n = base, 2
    while db.query(Model.id).filter(Model.slug == slug).first() or (settings.library_dir / slug).exists():
        slug = f"{base}-{n}"
        n += 1
    return slug


def model_dir(model: Model) -> Path:
    if model.deleted_at:
        return settings.trash_dir / model.slug
    return settings.library_dir / model.slug


def file_path(f: File) -> Path:
    return model_dir(f.model) / f.rel_path


def safe_rel_path(rel: str) -> str:
    """Normalise an uploaded relative path and refuse traversal outside the model folder."""
    parts = [p for p in Path(rel.replace("\\", "/")).parts if p not in ("", ".", "..", "/")]
    parts = [re.sub(r'[<>:"|?*\x00-\x1f]', "_", p) for p in parts]
    if not parts:
        raise ValueError("empty path")
    return "/".join(parts)


def unique_rel_path(model: Model, rel: str) -> str:
    existing = {f.rel_path for f in model.files}
    if rel not in existing and not (model_dir(model) / rel).exists():
        return rel
    p = Path(rel)
    n = 2
    while True:
        cand = str(p.with_name(f"{p.stem} ({n}){p.suffix}"))
        if cand not in existing and not (model_dir(model) / cand).exists():
            return cand
        n += 1


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def chown_like_owner(path: Path) -> None:
    uid, gid = os.environ.get("PUID"), os.environ.get("PGID")
    if uid and gid and os.geteuid() == 0:
        try:
            os.chown(path, int(uid), int(gid))
        except OSError:
            pass


def write_sidecar(model: Model) -> None:
    d = model_dir(model)
    if not d.exists():
        return
    data = {
        "name": model.name,
        "description": model.description,
        "category": category_path(model),
        "tags": [t.name for t in model.tags],
        "source_url": model.source_url,
        "author": model.author,
        "license": model.license,
        "print_notes": model.print_notes,
        "printers": [p.name for p in model.printers],
        "created_at": model.created_at.isoformat() if model.created_at else None,
    }
    tmp = d / f".{SIDECAR}.tmp"
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    tmp.replace(d / SIDECAR)
    chown_like_owner(d / SIDECAR)


def read_sidecar(d: Path) -> dict:
    try:
        return json.loads((d / SIDECAR).read_text())
    except (OSError, ValueError):
        return {}


def category_path(model: Model) -> list[str]:
    names = []
    c = model.category
    while c is not None:
        names.insert(0, c.name)
        c = c.parent
    return names


def move_to_trash(model: Model) -> None:
    src = settings.library_dir / model.slug
    if src.exists():
        dst = settings.trash_dir / model.slug
        if dst.exists():
            shutil.rmtree(dst)
        shutil.move(str(src), str(dst))


def restore_from_trash(model: Model) -> None:
    src = settings.trash_dir / model.slug
    if src.exists():
        shutil.move(str(src), str(settings.library_dir / model.slug))


def purge_files(model: Model) -> None:
    for d in (settings.trash_dir / model.slug, settings.library_dir / model.slug):
        if d.exists():
            shutil.rmtree(d, ignore_errors=True)
    for f in model.files:
        remove_derived(f.id)


def remove_derived(file_id: int) -> None:
    for p in (
        settings.thumbs_dir / f"{file_id}.webp",
        settings.previews_dir / f"{file_id}.glb",
        *settings.previews_dir.glob(f"{file_id}_lod*.glb"),
    ):
        p.unlink(missing_ok=True)


def thumb_path(file_id: int) -> Path:
    return settings.thumbs_dir / f"{file_id}.webp"


def preview_path(file_id: int, lod: bool = False) -> Path:
    from .mesh import LOD_VERSION

    return settings.previews_dir / (f"{file_id}_lod{LOD_VERSION}.glb" if lod else f"{file_id}.glb")


def update_fts(db: Session, model: Model) -> None:
    db.execute(text("DELETE FROM model_fts WHERE model_id = :id"), {"id": model.id})
    if model.deleted_at:
        return
    db.execute(
        text(
            "INSERT INTO model_fts(model_id, name, description, tags, filenames, author) "
            "VALUES (:id, :name, :desc, :tags, :files, :author)"
        ),
        {
            "id": model.id,
            "name": model.name,
            "desc": f"{model.description}\n{model.print_notes}",
            "tags": " ".join(t.name for t in model.tags),
            "files": " ".join(Path(f.rel_path).stem.replace("_", " ") for f in model.files),
            "author": model.author,
        },
    )
