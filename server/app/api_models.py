import shutil
import tempfile
import zipfile
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Request
from starlette.datastructures import UploadFile
from fastapi.responses import FileResponse
from sqlalchemy import func
from sqlalchemy.orm import Session

from . import services
from .auth import current_user
from .config import settings
from .db import get_db
from .library import (
    category_path,
    file_path,
    model_dir,
    move_to_trash,
    preview_path,
    purge_files,
    restore_from_trash,
    thumb_path,
    update_fts,
    write_sidecar,
)
from .models import Collection, File, Flag, Model, Printer, Setting, User, UserModel, utcnow
from .query import build_query, clean_params
from .schemas import (
    BulkAction,
    FileOut,
    FlagIn,
    FlagOut,
    ModelDetail,
    ModelPage,
    ModelPatch,
    ModelSummary,
    MyState,
    MyStatePatch,
    UserOut,
)

router = APIRouter(prefix="/api/v1", tags=["models"])

STATUSES = {"to_print", "printed", "failed", "needs_remix"}
FLAG_KINDS = {"broken_mesh", "missing_parts", "bad_scale", "other"}


def _my_states(db: Session, user: User, ids: list[int]) -> dict[int, UserModel]:
    if not ids:
        return {}
    rows = db.query(UserModel).filter(UserModel.user_id == user.id, UserModel.model_id.in_(ids)).all()
    return {r.model_id: r for r in rows}


def _my(state: UserModel | None) -> MyState:
    if state is None:
        return MyState()
    return MyState(favourite=state.favourite, rating=state.rating, status=state.status)


def _preview_file(m: Model) -> File | None:
    previews = [f for f in m.files if f.has_preview]
    if not previews:
        return None
    cover = next((f for f in previews if f.id == m.cover_file_id), None)
    return cover or max(previews, key=lambda f: f.tri_count or 0)


def summary(m: Model, state: UserModel | None) -> dict:
    pf = _preview_file(m)
    return dict(
        id=m.id,
        slug=m.slug,
        name=m.name,
        category_id=m.category_id,
        tags=[t.name for t in m.tags],
        cover_file_id=m.cover_file_id,
        cover_has_preview=bool(pf and pf.id == m.cover_file_id),
        preview_file_id=pf.id if pf else None,
        untriaged=m.untriaged,
        size_x=m.size_x,
        size_y=m.size_y,
        size_z=m.size_z,
        part_count=m.part_count,
        tri_count=m.tri_count,
        flag_count=sum(1 for f in m.flags if not f.resolved),
        created_at=m.created_at,
        updated_at=m.updated_at,
        deleted_at=m.deleted_at,
        me=_my(state),
        processing=any(f.status == "pending" for f in m.files),
    )


def detail(db: Session, m: Model, user: User) -> ModelDetail:
    state = _my_states(db, user, [m.id]).get(m.id)
    coll_ids = [c.id for c in db.query(Collection).filter(Collection.models.any(Model.id == m.id))]
    return ModelDetail(
        **summary(m, state),
        description=m.description,
        source_url=m.source_url,
        author=m.author,
        license=m.license,
        print_notes=m.print_notes,
        printer_ids=[p.id for p in m.printers],
        uploader=UserOut.model_validate(m.uploader, from_attributes=True) if m.uploader else None,
        category_path=category_path(m),
        files=[FileOut.model_validate(f, from_attributes=True) for f in m.files],
        flags=[FlagOut.model_validate(f, from_attributes=True) for f in m.flags],
        collection_ids=coll_ids,
    )


def get_model(db: Session, model_id: int, allow_trashed: bool = False) -> Model:
    m = db.get(Model, model_id)
    if m is None or (m.deleted_at and not allow_trashed):
        raise HTTPException(404, "Model not found")
    return m


def can_delete(user: User, m: Model) -> bool:
    return user.role == "admin" or m.uploader_id == user.id


def touch(db: Session, m: Model) -> None:
    m.updated_at = utcnow()
    db.flush()
    update_fts(db, m)
    write_sidecar(m)


# ---------------------------------------------------------------- listing


@router.get("/models", response_model=ModelPage)
def list_models(request: Request, page: int = 1, page_size: int = 60, db: Session = Depends(get_db), user: User = Depends(current_user)):
    params = dict(request.query_params)
    params["tags"] = request.query_params.getlist("tags") or params.get("tags")
    for multi in ("status", "ext", "flag_kind"):
        params[multi] = request.query_params.getlist(multi) or params.get(multi)
    if params.get("collection_id"):
        coll = db.get(Collection, int(params["collection_id"]))
        if coll and coll.kind == "smart":
            params = {**coll.query, **{k: v for k, v in clean_params(params).items() if k != "collection_id"}}
    q = build_query(db, user, clean_params(params))
    page_size = max(1, min(page_size, 500))
    total = q.order_by(None).with_entities(func.count(Model.id)).scalar()
    items = q.offset((max(page, 1) - 1) * page_size).limit(page_size).all()
    states = _my_states(db, user, [m.id for m in items])
    return ModelPage(
        items=[ModelSummary(**summary(m, states.get(m.id))) for m in items],
        total=total,
        page=page,
        page_size=page_size,
    )


@router.get("/models/{model_id}", response_model=ModelDetail)
def read_model(model_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    return detail(db, get_model(db, model_id, allow_trashed=True), user)


@router.patch("/models/{model_id}", response_model=ModelDetail)
def patch_model(model_id: int, body: ModelPatch, db: Session = Depends(get_db), user: User = Depends(current_user)):
    m = get_model(db, model_id)
    data = body.model_dump(exclude_unset=True)
    for field in ("name", "description", "source_url", "author", "license", "print_notes"):
        if field in data and data[field] is not None:
            setattr(m, field, data[field])
    if body.clear_category:
        m.category_id = None
    elif data.get("category_id") is not None:
        m.category_id = body.category_id
        m.untriaged = False
    if body.untriaged is not None:
        m.untriaged = body.untriaged
    if body.tags is not None:
        m.tags = services.get_or_create_tags(db, body.tags)
    if body.printer_ids is not None:
        m.printers = db.query(Printer).filter(Printer.id.in_(body.printer_ids)).all()
    if "cover_file_id" in data:
        if body.cover_file_id is None or any(f.id == body.cover_file_id and f.has_thumb for f in m.files):
            m.cover_file_id = body.cover_file_id
    db.flush()
    db.refresh(m)
    if m.cover_file_id is None:
        services.refresh_model(db, m)
    touch(db, m)
    db.commit()
    return detail(db, m, user)


@router.put("/models/{model_id}/me", response_model=MyState)
def set_my_state(model_id: int, body: MyStatePatch, db: Session = Depends(get_db), user: User = Depends(current_user)):
    get_model(db, model_id)
    state = db.get(UserModel, (user.id, model_id)) or UserModel(user_id=user.id, model_id=model_id)
    db.add(state)
    _apply_state(state, body.favourite, body.rating, body.status)
    db.commit()
    return _my(state)


def _apply_state(state: UserModel, favourite: bool | None, rating: int | None, status: str | None) -> None:
    if favourite is not None:
        state.favourite = favourite
    if rating is not None:
        state.rating = rating or None
    if status is not None:
        if status and status not in STATUSES:
            raise HTTPException(400, f"status must be one of {sorted(STATUSES)}")
        state.status = status or None


@router.delete("/models/{model_id}", status_code=204)
def delete_model(model_id: int, purge: bool = False, db: Session = Depends(get_db), user: User = Depends(current_user)):
    m = get_model(db, model_id, allow_trashed=True)
    if not can_delete(user, m):
        raise HTTPException(403, "Only the uploader or an admin can delete this model")
    _trash(db, m, purge)
    db.commit()


def _trash(db: Session, m: Model, purge: bool = False) -> None:
    if purge:
        purge_files(m)
        db.delete(m)
        return
    if m.deleted_at:
        return
    move_to_trash(m)
    m.deleted_at = utcnow()
    db.flush()
    update_fts(db, m)


@router.post("/models/{model_id}/restore", response_model=ModelDetail)
def restore_model(model_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    m = get_model(db, model_id, allow_trashed=True)
    if m.deleted_at:
        restore_from_trash(m)
        m.deleted_at = None
        db.flush()
        update_fts(db, m)
        db.commit()
    return detail(db, m, user)


@router.post("/models/bulk")
def bulk(body: BulkAction, db: Session = Depends(get_db), user: User = Depends(current_user)):
    models = db.query(Model).filter(Model.id.in_(body.ids)).all()
    add_tags = services.get_or_create_tags(db, body.add_tags)
    remove = {t.lower() for t in body.remove_tags}
    coll_add = db.get(Collection, body.add_to_collection) if body.add_to_collection else None
    coll_remove = db.get(Collection, body.remove_from_collection) if body.remove_from_collection else None
    printers = db.query(Printer).filter(Printer.id.in_(body.printer_ids_add)).all() if body.printer_ids_add else []
    if body.add_flag and body.add_flag.kind not in FLAG_KINDS:
        raise HTTPException(400, "Unknown flag kind")
    skipped = 0
    for m in models:
        if body.restore and m.deleted_at:
            restore_from_trash(m)
            m.deleted_at = None
        if m.deleted_at:
            continue
        if body.delete:
            if can_delete(user, m):
                _trash(db, m)
            else:
                skipped += 1
            continue
        if body.clear_category:
            m.category_id = None
        elif body.category_id is not None:
            m.category_id = body.category_id
            m.untriaged = False
        if body.untriaged is not None:
            m.untriaged = body.untriaged
        for t in add_tags:
            if t not in m.tags:
                m.tags.append(t)
        if remove:
            m.tags = [t for t in m.tags if t.name not in remove]
        for p in printers:
            if p not in m.printers:
                m.printers.append(p)
        if body.status is not None or body.favourite is not None:
            state = db.get(UserModel, (user.id, m.id)) or UserModel(user_id=user.id, model_id=m.id)
            db.add(state)
            _apply_state(state, body.favourite, None, body.status)
        if body.add_flag:
            db.add(Flag(model_id=m.id, kind=body.add_flag.kind, note=body.add_flag.note, user_id=user.id))
        if coll_add and m not in coll_add.models:
            coll_add.models.append(m)
        if coll_remove and m in coll_remove.models:
            coll_remove.models.remove(m)
        touch(db, m)
    db.commit()
    return {"updated": len(models) - skipped, "skipped": skipped}


# ---------------------------------------------------------------- flags


@router.post("/models/{model_id}/flags", response_model=FlagOut)
def add_flag(model_id: int, body: FlagIn, db: Session = Depends(get_db), user: User = Depends(current_user)):
    get_model(db, model_id)
    if body.kind not in FLAG_KINDS:
        raise HTTPException(400, f"kind must be one of {sorted(FLAG_KINDS)}")
    flag = Flag(model_id=model_id, kind=body.kind, note=body.note, user_id=user.id)
    db.add(flag)
    db.commit()
    return FlagOut.model_validate(flag, from_attributes=True)


@router.patch("/flags/{flag_id}", response_model=FlagOut)
def resolve_flag(flag_id: int, resolved: bool = True, db: Session = Depends(get_db), user: User = Depends(current_user)):
    flag = db.get(Flag, flag_id)
    if flag is None:
        raise HTTPException(404)
    flag.resolved = resolved
    db.commit()
    return FlagOut.model_validate(flag, from_attributes=True)


@router.delete("/flags/{flag_id}", status_code=204)
def delete_flag(flag_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    flag = db.get(Flag, flag_id)
    if flag:
        db.delete(flag)
        db.commit()


# ---------------------------------------------------------------- files


@router.post("/models/{model_id}/files", response_model=ModelDetail)
async def upload_to_model(model_id: int, request: Request, db: Session = Depends(get_db), user: User = Depends(current_user)):
    """Add files to an existing model. Form fields: files[] and optional photo=true."""
    m = get_model(db, model_id)
    form = await request.form()
    as_photo = str(form.get("photo", "")).lower() == "true"
    for up in form.getlist("files"):
        if not isinstance(up, UploadFile) or not up.filename:
            continue
        tmp = Path(tempfile.mkstemp(dir=settings.staging_dir)[1])
        with open(tmp, "wb") as out:
            shutil.copyfileobj(up.file, out, 1024 * 1024)
        rel = f"photos/{Path(up.filename).name}" if as_photo else up.filename
        f = services.add_file(db, m, tmp, rel, user, kind="photo" if as_photo else None)
        if as_photo:
            m.cover_file_id = None  # let the new print photo become the cover once processed
    db.flush()
    db.refresh(m)
    services.refresh_model(db, m)
    touch(db, m)
    db.commit()
    return detail(db, m, user)


@router.delete("/files/{file_id}", status_code=204)
def delete_file(file_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    f = db.get(File, file_id)
    if f is None:
        raise HTTPException(404)
    if not (user.role == "admin" or f.uploaded_by == user.id or f.model.uploader_id == user.id):
        raise HTTPException(403, "Only the uploader or an admin can delete files")
    services.delete_file(db, f)
    db.commit()


@router.post("/files/{file_id}/reprocess", status_code=202)
def reprocess_file(file_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    f = db.get(File, file_id)
    if f is None:
        raise HTTPException(404)
    f.status = "pending"
    services.enqueue(db, "process_file", file_id=f.id)
    db.commit()
    return {"queued": True}


def _file_or_404(db: Session, file_id: int) -> File:
    f = db.get(File, file_id)
    if f is None:
        raise HTTPException(404)
    return f


CACHE_FOREVER = {"Cache-Control": "private, max-age=31536000, immutable"}


@router.get("/files/{file_id}/download")
def download_file(file_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    f = _file_or_404(db, file_id)
    path = file_path(f)
    if not path.exists():
        raise HTTPException(404, "File missing on disk")
    return FileResponse(path, filename=Path(f.rel_path).name)


@router.get("/files/{file_id}/thumb")
def file_thumb(file_id: int, v: str = "", user: User = Depends(current_user)):
    path = thumb_path(file_id)
    if not path.exists():
        raise HTTPException(404)
    return FileResponse(path, media_type="image/webp", headers=CACHE_FOREVER if v else {})


@router.get("/files/{file_id}/preview")
def file_preview(file_id: int, lod: bool = False, user: User = Depends(current_user)):
    path = preview_path(file_id, lod)
    full = preview_path(file_id)
    if lod and not path.exists() and full.exists():
        from . import mesh

        mesh.build_lod(full, path)
        for old in settings.previews_dir.glob(f"{file_id}_lod*.glb"):
            if old != path:
                old.unlink(missing_ok=True)
    if not path.exists():
        raise HTTPException(404)
    return FileResponse(path, media_type="model/gltf-binary", headers=CACHE_FOREVER)


@router.get("/models/{model_id}/download")
def download_model(model_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    m = get_model(db, model_id)
    out = settings.cache_dir / f"model-{m.id}-{int(m.updated_at.timestamp())}.zip"
    if not out.exists():
        for old in settings.cache_dir.glob(f"model-{m.id}-*.zip"):
            old.unlink(missing_ok=True)
        tmp = out.with_suffix(".tmp")
        base = model_dir(m)
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=5) as z:
            for f in m.files:
                p = base / f.rel_path
                if p.exists():
                    z.write(p, f"{m.slug}/{f.rel_path}")
            if (base / "model.json").exists():
                z.write(base / "model.json", f"{m.slug}/model.json")
        tmp.replace(out)
    return FileResponse(out, filename=f"{m.slug}.zip", media_type="application/zip")


# ---------------------------------------------------------------- url import


@router.post("/models/{model_id}/import-url", response_model=ModelDetail)
def import_url(model_id: int, url: str, overwrite: bool = False, db: Session = Depends(get_db), user: User = Depends(current_user)):
    from .urlmeta import MetaError, fetch

    m = get_model(db, model_id)
    token = (db.get(Setting, "thingiverse_token") or Setting(value="")).value
    try:
        meta = fetch(url, token)
    except MetaError as e:
        raise HTTPException(422, str(e))
    except Exception as e:
        raise HTTPException(502, f"Could not fetch metadata: {e}")
    services.apply_url_meta(db, m, meta, overwrite=overwrite)
    m.source_url = meta.get("source_url") or url
    touch(db, m)
    db.commit()
    db.refresh(m)
    return detail(db, m, user)
