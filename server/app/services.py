"""Model-level operations shared by the API, importer and worker."""

import re
import shutil
from pathlib import Path

from sqlalchemy.orm import Session

from .formats import classify, file_ext
from .library import (
    chown_like_owner,
    model_dir,
    remove_derived,
    safe_rel_path,
    sha256_file,
    unique_rel_path,
    unique_slug,
    update_fts,
    write_sidecar,
)
from .models import Category, File, Job, Model, Rule, Tag, User

COVER_ORDER = {"photo": 0, "image": 1, "mesh": 2, "cad": 2, "gcode": 3}


def enqueue(db: Session, kind: str, **payload) -> None:
    db.add(Job(kind=kind, payload=payload))


def get_or_create_tags(db: Session, names: list[str]) -> list[Tag]:
    out = []
    for raw in names:
        name = re.sub(r"\s+", " ", raw.strip().lower())[:64]
        if not name:
            continue
        tag = db.query(Tag).filter(Tag.name == name).first()
        if tag is None:
            tag = Tag(name=name)
            db.add(tag)
            db.flush()
        if tag not in out:
            out.append(tag)
    return out


def get_or_create_category_path(db: Session, path: list[str]) -> Category | None:
    parent = None
    for name in path:
        name = name.strip()
        if not name:
            continue
        cat = (
            db.query(Category)
            .filter(Category.name == name, Category.parent_id == (parent.id if parent else None))
            .first()
        )
        if cat is None:
            cat = Category(name=name, parent_id=parent.id if parent else None)
            db.add(cat)
            db.flush()
        parent = cat
    return parent


def add_file(db: Session, model: Model, src: Path, rel_path: str, user: User | None, kind: str | None = None, move: bool = True) -> File:
    rel = unique_rel_path(model, safe_rel_path(rel_path))
    dest = model_dir(model) / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    if move:
        shutil.move(str(src), str(dest))
    else:
        shutil.copy2(src, dest)
    chown_like_owner(dest)
    f = File(
        model=model,
        rel_path=rel,
        kind=kind or classify(rel),
        ext=file_ext(rel),
        size=dest.stat().st_size,
        sha256=sha256_file(dest),
        uploaded_by=user.id if user else None,
    )
    db.add(f)
    db.flush()
    if f.kind in ("mesh", "cad", "gcode", "image", "photo"):
        enqueue(db, "process_file", file_id=f.id)
    else:
        f.status = "ready"
    return f


def register_in_place(db: Session, model: Model, rel: str) -> File:
    """Index a file that already sits in the model folder (added over SMB, or a rescan)."""
    path = model_dir(model) / rel
    f = File(
        model=model,
        rel_path=rel,
        kind=classify(rel),
        ext=file_ext(rel),
        size=path.stat().st_size,
        sha256=sha256_file(path),
    )
    db.add(f)
    db.flush()
    if f.kind in ("mesh", "cad", "gcode", "image", "photo"):
        enqueue(db, "process_file", file_id=f.id)
    else:
        f.status = "ready"
    return f


def apply_url_meta(db: Session, model: Model, meta: dict, overwrite: bool = False) -> None:
    from .urlmeta import download_images

    for field in ("name", "description", "author", "license", "source_url"):
        value = (meta.get(field) or "").strip()
        if value and (overwrite or not getattr(model, field) or (field == "name" and model.untriaged)):
            setattr(model, field, value[:1024] if field == "source_url" else value)
    for tag in get_or_create_tags(db, meta.get("tags") or []):
        if tag not in model.tags:
            model.tags.append(tag)
    has_images = any(f.kind == "image" for f in model.files)
    if meta.get("images") and (overwrite or not has_images):
        for i, tmp in enumerate(download_images(meta["images"])):
            add_file(db, model, tmp, f"images/{model.slug}-{i + 1}{tmp.suffix}", None, kind="image")
    db.flush()
    refresh_model(db, model)


def delete_file(db: Session, f: File) -> None:
    path = model_dir(f.model) / f.rel_path
    path.unlink(missing_ok=True)
    remove_derived(f.id)
    model = f.model
    if model.cover_file_id == f.id:
        model.cover_file_id = None
    db.delete(f)
    db.flush()
    refresh_model(db, model)


def create_model(db: Session, name: str, user: User | None) -> Model:
    model = Model(name=name.strip() or "Untitled", slug=unique_slug(db, name), uploader_id=user.id if user else None)
    db.add(model)
    db.flush()
    model_dir(model).mkdir(parents=True, exist_ok=True)
    chown_like_owner(model_dir(model))
    return model


def apply_rules(db: Session, model: Model, rules: list[Rule] | None = None) -> None:
    rules = rules if rules is not None else db.query(Rule).filter(Rule.enabled.is_(True)).all()
    filenames = " ".join(f.rel_path for f in model.files).lower()
    for rule in rules:
        pat = rule.pattern.lower().strip()
        if not pat:
            continue
        haystack = {
            "filename": filenames,
            "name": model.name.lower(),
            "source_url": model.source_url.lower(),
        }.get(rule.field, f"{filenames} {model.name.lower()} {model.source_url.lower()}")
        if pat not in haystack:
            continue
        for tag in get_or_create_tags(db, rule.add_tags or []):
            if tag not in model.tags:
                model.tags.append(tag)
        if rule.category_id and model.category_id is None:
            model.category_id = rule.category_id


def refresh_model(db: Session, model: Model) -> None:
    """Recompute aggregates, pick a cover, refresh search index and sidecar."""
    parts = [f for f in model.files if f.kind in ("mesh", "cad") and f.size_x is not None]
    model.part_count = len([f for f in model.files if f.kind in ("mesh", "cad")])
    model.tri_count = sum(f.tri_count or 0 for f in parts)
    if parts:
        dims = []
        for f in parts:
            for d in (f.meta or {}).get("parts") or [[f.size_x, f.size_y, f.size_z]]:
                dims.append(sorted(d, reverse=True))
        model.fit_a = max(d[0] for d in dims)
        model.fit_b = max(d[1] for d in dims)
        model.fit_c = max(d[2] for d in dims)
        biggest = max(parts, key=lambda f: f.size_x * f.size_y * f.size_z)
        model.size_x, model.size_y, model.size_z = biggest.size_x, biggest.size_y, biggest.size_z
    else:
        model.fit_a = model.fit_b = model.fit_c = None
        model.size_x = model.size_y = model.size_z = None

    ids = {f.id for f in model.files if f.has_thumb}
    if model.cover_file_id not in ids:
        model.cover_file_id = None
    if model.cover_file_id is None:
        candidates = [f for f in model.files if f.has_thumb and f.kind in COVER_ORDER]
        if candidates:
            best = min(candidates, key=lambda f: (COVER_ORDER[f.kind], -(f.tri_count or 0), f.rel_path))
            model.cover_file_id = best.id
    db.flush()
    update_fts(db, model)
    write_sidecar(model)
