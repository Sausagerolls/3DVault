"""Model search/filter query builder. Saved smart collections store these same params."""

import re
from datetime import datetime

from sqlalchemy import and_, exists, func, or_, select, text
from sqlalchemy.orm import Query, Session

from .models import (
    File,
    Flag,
    Model,
    Printer,
    Tag,
    User,
    UserModel,
    collection_models,
    model_tags,
)

FILTER_KEYS = {
    "q", "category_id", "tags", "status", "favourite", "min_rating", "flagged", "flag_kind", "ext",
    "uploader_id", "added_after", "added_before", "printer_id", "max_x", "max_y", "max_z", "min_tris",
    "max_tris", "min_parts", "max_parts", "untriaged", "collection_id", "trashed", "sort",
}
SORTS = {
    "new": Model.created_at.desc(),
    "old": Model.created_at.asc(),
    "name": func.lower(Model.name).asc(),
    "updated": Model.updated_at.desc(),
    "size": Model.fit_a.desc(),
    "tris": Model.tri_count.desc(),
}


def category_descendants(db: Session, root_id: int) -> list[int]:
    rows = db.execute(
        text(
            "WITH RECURSIVE sub(id) AS (SELECT :id UNION ALL "
            "SELECT c.id FROM categories c JOIN sub ON c.parent_id = sub.id) SELECT id FROM sub"
        ),
        {"id": root_id},
    ).all()
    return [r[0] for r in rows]


def fts_query(q: str) -> str:
    words = re.findall(r"\w+", q.lower())
    return " ".join(f'"{w}"*' for w in words)


def _list(v) -> list:
    if v is None or v == "":
        return []
    if isinstance(v, list):
        return [x for x in v if x not in (None, "")]
    return [x for x in str(v).split(",") if x]


def _bool(v) -> bool | None:
    if v is None or v == "":
        return None
    if isinstance(v, bool):
        return v
    return str(v).lower() in ("1", "true", "yes")


def build_query(db: Session, user: User, p: dict) -> Query:
    q = db.query(Model)
    trashed = _bool(p.get("trashed"))
    q = q.filter(Model.deleted_at.isnot(None) if trashed else Model.deleted_at.is_(None))

    if p.get("q"):
        match = fts_query(p["q"])
        if match:
            ids = select(text("model_id")).select_from(text("model_fts")).where(text("model_fts MATCH :m"))
            q = q.filter(Model.id.in_(ids)).params(m=match)

    if p.get("category_id"):
        cid = int(p["category_id"])
        if cid == -1:
            q = q.filter(Model.category_id.is_(None))
        else:
            q = q.filter(Model.category_id.in_(category_descendants(db, cid)))

    for name in _list(p.get("tags")):
        q = q.filter(
            exists().where(
                and_(model_tags.c.model_id == Model.id, model_tags.c.tag_id == Tag.id, Tag.name == name.lower())
            )
        )

    my = and_(UserModel.model_id == Model.id, UserModel.user_id == user.id)
    statuses = _list(p.get("status"))
    if statuses:
        conds = []
        real = [s for s in statuses if s != "none"]
        if real:
            conds.append(exists().where(and_(my, UserModel.status.in_(real))))
        if "none" in statuses:
            conds.append(~exists().where(and_(my, UserModel.status.isnot(None))))
        q = q.filter(or_(*conds))
    if _bool(p.get("favourite")):
        q = q.filter(exists().where(and_(my, UserModel.favourite.is_(True))))
    if p.get("min_rating"):
        q = q.filter(exists().where(and_(my, UserModel.rating >= int(p["min_rating"]))))

    open_flag = and_(Flag.model_id == Model.id, Flag.resolved.is_(False))
    flagged = _bool(p.get("flagged"))
    if flagged is True:
        q = q.filter(exists().where(open_flag))
    elif flagged is False:
        q = q.filter(~exists().where(open_flag))
    kinds = _list(p.get("flag_kind"))
    if kinds:
        q = q.filter(exists().where(and_(open_flag, Flag.kind.in_(kinds))))

    exts = [e.lower().lstrip(".") for e in _list(p.get("ext"))]
    if exts:
        if "step" in exts:
            exts.append("stp")
        q = q.filter(exists().where(and_(File.model_id == Model.id, File.ext.in_(exts))))

    if p.get("uploader_id"):
        q = q.filter(Model.uploader_id == int(p["uploader_id"]))
    if p.get("added_after"):
        q = q.filter(Model.created_at >= datetime.fromisoformat(str(p["added_after"])))
    if p.get("added_before"):
        q = q.filter(Model.created_at <= datetime.fromisoformat(str(p["added_before"])))

    bed = None
    if p.get("printer_id"):
        pr = db.get(Printer, int(p["printer_id"]))
        if pr:
            bed = sorted([pr.x, pr.y, pr.z], reverse=True)
    elif any(p.get(k) for k in ("max_x", "max_y", "max_z")):
        bed = sorted([float(p.get(k) or 1e9) for k in ("max_x", "max_y", "max_z")], reverse=True)
    if bed:
        q = q.filter(Model.fit_a <= bed[0], Model.fit_b <= bed[1], Model.fit_c <= bed[2])

    for key, col, op in (
        ("min_tris", Model.tri_count, "ge"),
        ("max_tris", Model.tri_count, "le"),
        ("min_parts", Model.part_count, "ge"),
        ("max_parts", Model.part_count, "le"),
    ):
        if p.get(key) not in (None, ""):
            v = int(p[key])
            q = q.filter(col >= v if op == "ge" else col <= v)

    untriaged = _bool(p.get("untriaged"))
    if untriaged is not None:
        q = q.filter(Model.untriaged.is_(untriaged))

    if p.get("collection_id"):
        q = q.filter(
            exists().where(
                and_(
                    collection_models.c.model_id == Model.id,
                    collection_models.c.collection_id == int(p["collection_id"]),
                )
            )
        )

    sort = p.get("sort") or "new"
    if sort == "rating":
        rating = (
            select(UserModel.rating).where(my).correlate(Model).scalar_subquery()
        )
        q = q.order_by(func.coalesce(rating, 0).desc(), Model.created_at.desc())
    else:
        q = q.order_by(SORTS.get(sort, SORTS["new"]), Model.id.desc())
    return q


def clean_params(p: dict) -> dict:
    return {k: v for k, v in p.items() if k in FILTER_KEYS and v not in (None, "", [])}


def category_counts(db: Session) -> dict[int, int]:
    rows = (
        db.query(Model.category_id, func.count(Model.id))
        .filter(Model.deleted_at.is_(None))
        .group_by(Model.category_id)
        .all()
    )
    return {cid or -1: n for cid, n in rows}


def tag_counts(db: Session) -> list[tuple[Tag, int]]:
    return (
        db.query(Tag, func.count(model_tags.c.model_id))
        .join(model_tags, model_tags.c.tag_id == Tag.id)
        .join(Model, and_(Model.id == model_tags.c.model_id, Model.deleted_at.is_(None)))
        .group_by(Tag.id)
        .order_by(func.count(model_tags.c.model_id).desc(), Tag.name)
        .all()
    )

