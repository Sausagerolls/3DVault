import shutil
import tempfile
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Request
from starlette.datastructures import UploadFile
from pydantic import BaseModel
from sqlalchemy import func
from sqlalchemy.orm import Session

from . import services
from .auth import current_user, require_admin
from .config import settings
from .db import get_db
from .importer import commit_batch, discard_batch, new_batch, propose_groups, stage_file
from .library import purge_files, update_fts, write_sidecar
from .models import (
    Category,
    Collection,
    Job,
    Model,
    Printer,
    Rule,
    Setting,
    Tag,
    UploadBatch,
    User,
    model_tags,
)
from .query import category_counts, clean_params, tag_counts
from .schemas import CategoryOut, CommitIn, PrinterOut, TagOut

router = APIRouter(prefix="/api/v1", tags=["library"])


# ---------------------------------------------------------------- categories


class CategoryIn(BaseModel):
    name: str
    parent_id: int | None = None
    sort: int = 0


@router.get("/categories", response_model=list[CategoryOut])
def list_categories(db: Session = Depends(get_db), user: User = Depends(current_user)):
    counts = category_counts(db)
    return [
        CategoryOut(id=c.id, name=c.name, parent_id=c.parent_id, count=counts.get(c.id, 0))
        for c in db.query(Category).order_by(Category.sort, func.lower(Category.name))
    ]


@router.post("/categories", response_model=CategoryOut)
def create_category(body: CategoryIn, db: Session = Depends(get_db), user: User = Depends(current_user)):
    if db.query(Category).filter(Category.name == body.name.strip(), Category.parent_id == body.parent_id).first():
        raise HTTPException(409, "Category already exists here")
    c = Category(name=body.name.strip(), parent_id=body.parent_id, sort=body.sort)
    db.add(c)
    db.commit()
    return CategoryOut(id=c.id, name=c.name, parent_id=c.parent_id)


@router.patch("/categories/{cat_id}", response_model=CategoryOut)
def patch_category(cat_id: int, body: CategoryIn, db: Session = Depends(get_db), user: User = Depends(current_user)):
    c = db.get(Category, cat_id)
    if c is None:
        raise HTTPException(404)
    # Refuse moving a category under itself or one of its children.
    p = db.get(Category, body.parent_id) if body.parent_id else None
    while p is not None:
        if p.id == c.id:
            raise HTTPException(400, "Cannot move a category inside itself")
        p = p.parent
    clash = db.query(Category).filter(Category.name == body.name.strip(), Category.parent_id == body.parent_id, Category.id != c.id).first()
    if clash:
        raise HTTPException(409, "A category with that name already exists there")
    c.name, c.parent_id, c.sort = body.name.strip(), body.parent_id, body.sort
    db.commit()
    for m in db.query(Model).filter(Model.deleted_at.is_(None), Model.category_id.isnot(None)):
        write_sidecar(m)
    return CategoryOut(id=c.id, name=c.name, parent_id=c.parent_id)


@router.delete("/categories/{cat_id}", status_code=204)
def delete_category(cat_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    c = db.get(Category, cat_id)
    if c is None:
        return
    # Models in this category move up to the parent, children move up too.
    db.query(Model).filter(Model.category_id == c.id).update({"category_id": c.parent_id})
    db.query(Category).filter(Category.parent_id == c.id).update({"parent_id": c.parent_id})
    db.delete(c)
    db.commit()


# ---------------------------------------------------------------- tags


class TagPatch(BaseModel):
    name: str


@router.get("/tags", response_model=list[TagOut])
def list_tags(db: Session = Depends(get_db), user: User = Depends(current_user)):
    return [TagOut(id=t.id, name=t.name, count=n) for t, n in tag_counts(db)]


@router.patch("/tags/{tag_id}", response_model=TagOut)
def rename_tag(tag_id: int, body: TagPatch, db: Session = Depends(get_db), user: User = Depends(current_user)):
    """Rename a tag. Renaming onto an existing tag merges them."""
    tag = db.get(Tag, tag_id)
    if tag is None:
        raise HTTPException(404)
    new = body.name.strip().lower()
    target = db.query(Tag).filter(Tag.name == new, Tag.id != tag.id).first()
    affected = db.query(Model).filter(Model.tags.any(Tag.id == tag.id)).all()
    if target:
        for m in affected:
            m.tags = [t for t in m.tags if t.id != tag.id] + ([] if target in m.tags else [target])
        db.delete(tag)
        tag = target
    else:
        tag.name = new
    db.flush()
    for m in affected:
        update_fts(db, m)
        write_sidecar(m)
    db.commit()
    return TagOut(id=tag.id, name=tag.name)


@router.delete("/tags/{tag_id}", status_code=204)
def delete_tag(tag_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    tag = db.get(Tag, tag_id)
    if tag:
        affected = db.query(Model).filter(Model.tags.any(Tag.id == tag.id)).all()
        db.delete(tag)
        db.flush()
        for m in affected:
            db.refresh(m)
            update_fts(db, m)
            write_sidecar(m)
        db.commit()


# ---------------------------------------------------------------- printers


class PrinterIn(BaseModel):
    name: str
    x: float
    y: float
    z: float


@router.get("/printers", response_model=list[PrinterOut])
def list_printers(db: Session = Depends(get_db), user: User = Depends(current_user)):
    return [PrinterOut.model_validate(p, from_attributes=True) for p in db.query(Printer).order_by(Printer.id)]


@router.post("/printers", response_model=PrinterOut)
def create_printer(body: PrinterIn, db: Session = Depends(get_db), user: User = Depends(current_user)):
    p = Printer(name=body.name.strip(), x=body.x, y=body.y, z=body.z)
    db.add(p)
    db.commit()
    return PrinterOut.model_validate(p, from_attributes=True)


@router.patch("/printers/{printer_id}", response_model=PrinterOut)
def patch_printer(printer_id: int, body: PrinterIn, db: Session = Depends(get_db), user: User = Depends(current_user)):
    p = db.get(Printer, printer_id)
    if p is None:
        raise HTTPException(404)
    p.name, p.x, p.y, p.z = body.name.strip(), body.x, body.y, body.z
    db.commit()
    return PrinterOut.model_validate(p, from_attributes=True)


@router.delete("/printers/{printer_id}", status_code=204)
def delete_printer(printer_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    db.query(Printer).filter(Printer.id == printer_id).delete()
    db.commit()


# ---------------------------------------------------------------- collections


class CollectionIn(BaseModel):
    name: str
    kind: str = "manual"
    query: dict = {}
    shared: bool = True


def _coll_out(c: Collection) -> dict:
    return {
        "id": c.id,
        "name": c.name,
        "kind": c.kind,
        "query": c.query,
        "shared": c.shared,
        "owner_id": c.owner_id,
        "count": len([m for m in c.models if not m.deleted_at]) if c.kind == "manual" else None,
    }


@router.get("/collections")
def list_collections(db: Session = Depends(get_db), user: User = Depends(current_user)):
    rows = db.query(Collection).filter((Collection.shared.is_(True)) | (Collection.owner_id == user.id))
    return [_coll_out(c) for c in rows.order_by(func.lower(Collection.name))]


@router.post("/collections")
def create_collection(body: CollectionIn, db: Session = Depends(get_db), user: User = Depends(current_user)):
    if body.kind not in ("manual", "smart"):
        raise HTTPException(400, "kind must be manual or smart")
    c = Collection(name=body.name.strip(), kind=body.kind, query=clean_params(body.query), shared=body.shared, owner_id=user.id)
    db.add(c)
    db.commit()
    return _coll_out(c)


@router.patch("/collections/{coll_id}")
def patch_collection(coll_id: int, body: CollectionIn, db: Session = Depends(get_db), user: User = Depends(current_user)):
    c = db.get(Collection, coll_id)
    if c is None:
        raise HTTPException(404)
    c.name, c.shared = body.name.strip(), body.shared
    if c.kind == "smart":
        c.query = clean_params(body.query)
    db.commit()
    return _coll_out(c)


@router.delete("/collections/{coll_id}", status_code=204)
def delete_collection(coll_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    c = db.get(Collection, coll_id)
    if c and (c.owner_id == user.id or user.role == "admin"):
        db.delete(c)
        db.commit()


# ---------------------------------------------------------------- rules


class RuleIn(BaseModel):
    name: str
    field: str = "any"
    pattern: str
    add_tags: list[str] = []
    category_id: int | None = None
    enabled: bool = True


def _rule_out(r: Rule) -> dict:
    return {k: getattr(r, k) for k in ("id", "name", "field", "pattern", "add_tags", "category_id", "enabled")}


@router.get("/rules")
def list_rules(db: Session = Depends(get_db), user: User = Depends(current_user)):
    return [_rule_out(r) for r in db.query(Rule).order_by(Rule.id)]


@router.post("/rules")
def create_rule(body: RuleIn, db: Session = Depends(get_db), user: User = Depends(current_user)):
    r = Rule(**body.model_dump())
    db.add(r)
    db.commit()
    return _rule_out(r)


@router.patch("/rules/{rule_id}")
def patch_rule(rule_id: int, body: RuleIn, db: Session = Depends(get_db), user: User = Depends(current_user)):
    r = db.get(Rule, rule_id)
    if r is None:
        raise HTTPException(404)
    for k, v in body.model_dump().items():
        setattr(r, k, v)
    db.commit()
    return _rule_out(r)


@router.delete("/rules/{rule_id}", status_code=204)
def delete_rule(rule_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    db.query(Rule).filter(Rule.id == rule_id).delete()
    db.commit()


@router.post("/rules/apply", status_code=202)
def apply_rules(untriaged_only: bool = True, db: Session = Depends(get_db), user: User = Depends(current_user)):
    services.enqueue(db, "apply_rules", untriaged_only=untriaged_only)
    db.commit()
    return {"queued": True}


# ---------------------------------------------------------------- settings / admin

PUBLIC_SETTINGS = {"thingiverse_token"}


@router.get("/settings")
def get_settings(db: Session = Depends(get_db), admin: User = Depends(require_admin)):
    return {s.key: s.value for s in db.query(Setting).filter(Setting.key.in_(PUBLIC_SETTINGS))}


@router.put("/settings")
def put_settings(body: dict, db: Session = Depends(get_db), admin: User = Depends(require_admin)):
    for k, v in body.items():
        if k in PUBLIC_SETTINGS:
            db.merge(Setting(key=k, value=str(v)))
    db.commit()
    return get_settings(db, admin)


@router.post("/admin/rescan", status_code=202)
def rescan(db: Session = Depends(get_db), admin: User = Depends(require_admin)):
    services.enqueue(db, "rescan")
    db.commit()
    return {"queued": True}


@router.get("/jobs/summary")
def jobs_summary(db: Session = Depends(get_db), user: User = Depends(current_user)):
    rows = db.query(Job.status, func.count(Job.id)).group_by(Job.status).all()
    errors = db.query(Job).filter(Job.status == "error").order_by(Job.id.desc()).limit(20).all()
    return {
        "counts": dict(rows),
        "recent_errors": [{"id": j.id, "kind": j.kind, "payload": j.payload, "error": j.error} for j in errors],
    }


@router.get("/stats")
def stats(db: Session = Depends(get_db), user: User = Depends(current_user)):
    live = db.query(Model).filter(Model.deleted_at.is_(None))
    return {
        "models": live.count(),
        "untriaged": live.filter(Model.untriaged.is_(True)).count(),
        "trash": db.query(Model).filter(Model.deleted_at.isnot(None)).count(),
        "tags": db.query(func.count(func.distinct(model_tags.c.tag_id))).scalar(),
        "trash_days": settings.trash_days,
    }


@router.post("/trash/empty", status_code=204)
def empty_trash(db: Session = Depends(get_db), user: User = Depends(current_user)):
    q = db.query(Model).filter(Model.deleted_at.isnot(None))
    if user.role != "admin":
        q = q.filter(Model.uploader_id == user.id)
    for m in q:
        purge_files(m)
        db.delete(m)
    db.commit()


# ---------------------------------------------------------------- uploads


def _batch(db: Session, batch_id: str, user: User) -> UploadBatch:
    b = db.get(UploadBatch, batch_id)
    if b is None or (b.user_id != user.id and user.role != "admin"):
        raise HTTPException(404, "Upload batch not found")
    return b


def _batch_out(b: UploadBatch) -> dict:
    return {"id": b.id, "files": b.files, "groups": propose_groups(b.files)}


@router.post("/uploads")
def create_batch(db: Session = Depends(get_db), user: User = Depends(current_user)):
    return _batch_out(new_batch(db, user, "web"))


@router.post("/uploads/{batch_id}/files")
async def upload_files(batch_id: str, request: Request, db: Session = Depends(get_db), user: User = Depends(current_user)):
    """multipart form: files[] plus optional parallel paths[] holding folder-relative paths."""
    b = _batch(db, batch_id, user)
    form = await request.form()
    uploads = [u for u in form.getlist("files") if isinstance(u, UploadFile)]
    paths = [str(p) for p in form.getlist("paths")]
    added = []
    for i, up in enumerate(uploads):
        client_path = paths[i] if i < len(paths) and paths[i] else (up.filename or f"file-{i}")
        tmp = Path(tempfile.mkstemp(dir=settings.staging_dir / b.id)[1])
        with open(tmp, "wb") as out:
            shutil.copyfileobj(up.file, out, 1024 * 1024)
        try:
            added += stage_file(db, b, tmp, client_path)
        except ValueError:
            tmp.unlink(missing_ok=True)
    return {"added": added, **_batch_out(b)}


@router.get("/uploads/{batch_id}")
def get_batch(batch_id: str, db: Session = Depends(get_db), user: User = Depends(current_user)):
    return _batch_out(_batch(db, batch_id, user))


@router.post("/uploads/{batch_id}/commit")
def commit(batch_id: str, body: CommitIn, db: Session = Depends(get_db), user: User = Depends(current_user)):
    b = _batch(db, batch_id, user)
    created = commit_batch(db, b, [g.model_dump() for g in body.groups], user)
    return {"model_ids": [m.id for m in created]}


@router.delete("/uploads/{batch_id}", status_code=204)
def discard(batch_id: str, db: Session = Depends(get_db), user: User = Depends(current_user)):
    discard_batch(db, _batch(db, batch_id, user))

