"""Upload staging, zip extraction and grouping of loose files into models."""

import re
import secrets
import shutil
import zipfile
from collections import OrderedDict
from pathlib import Path, PurePosixPath

from sqlalchemy.orm import Session

from .config import settings
from .formats import classify
from .library import safe_rel_path, sha256_file
from .models import File, Model, UploadBatch, User
from .services import add_file, apply_rules, create_model, enqueue, get_or_create_tags, refresh_model

JUNK = {".ds_store", "thumbs.db", "desktop.ini"}
GENERIC_DIRS = {
    "files", "file", "stl", "stls", "3mf", "step", "images", "image", "img", "photos", "pictures",
    "renders", "print files", "printfiles", "models", "parts", "gcode", "docs", "source", "cad",
}
PART_WORDS = {
    "part", "parts", "top", "bottom", "left", "right", "base", "lid", "body", "cover", "front", "back",
    "v", "final", "fixed", "repaired", "print", "printable", "copy", "x",
}


def new_batch(db: Session, user: User, source: str = "web") -> UploadBatch:
    batch = UploadBatch(id=secrets.token_hex(8), user_id=user.id, source=source, files=[])
    db.add(batch)
    db.commit()
    batch_dir(batch).mkdir(parents=True, exist_ok=True)
    return batch


def batch_dir(batch: UploadBatch) -> Path:
    return settings.staging_dir / batch.id


def _is_junk(path: str) -> bool:
    p = PurePosixPath(path)
    return (
        any(part.startswith("__MACOSX") or part.startswith("._") for part in p.parts)
        or p.name.lower() in JUNK
        or p.name.startswith(".")
    )


def _dup_lookup(db: Session, sha: str) -> int | None:
    row = (
        db.query(File.model_id)
        .join(Model, Model.id == File.model_id)
        .filter(File.sha256 == sha, Model.deleted_at.is_(None))
        .first()
    )
    return row[0] if row else None


def stage_file(db: Session, batch: UploadBatch, tmp: Path, client_path: str) -> list[dict]:
    """Move an uploaded temp file into the batch. Zips are extracted; each entry gets a group hint."""
    client_path = client_path.replace("\\", "/").lstrip("/")
    if _is_junk(client_path):
        tmp.unlink(missing_ok=True)
        return []
    base = batch_dir(batch)
    added: list[dict] = []
    rel_client = safe_rel_path(client_path)
    in_folder = "/" in rel_client

    if rel_client.lower().endswith(".zip") and zipfile.is_zipfile(tmp):
        hint = "zip:" + (str(PurePosixPath(rel_client).with_suffix("")))
        with zipfile.ZipFile(tmp) as z:
            names = [n for n in z.namelist() if not n.endswith("/") and not _is_junk(n)]
            # Strip a single wrapping folder so "Benchy/files/x.stl" becomes "files/x.stl".
            tops = {n.split("/", 1)[0] for n in names}
            strip = len(tops) == 1 and all("/" in n for n in names)
            for n in names:
                inner = n.split("/", 1)[1] if strip else n
                try:
                    rel = safe_rel_path(inner)
                except ValueError:
                    continue
                entry_id = secrets.token_hex(6)
                dest = base / entry_id
                with z.open(n) as src, open(dest, "wb") as out:
                    shutil.copyfileobj(src, out, 1024 * 1024)
                added.append(_entry(db, entry_id, dest, rel, hint))
        tmp.unlink(missing_ok=True)
    else:
        entry_id = secrets.token_hex(6)
        dest = base / entry_id
        shutil.move(str(tmp), dest)
        added.append(_entry(db, entry_id, dest, rel_client, "folder" if in_folder else "loose"))

    batch.files = list(batch.files) + added
    db.commit()
    return added


def _entry(db: Session, entry_id: str, stored: Path, rel: str, hint: str) -> dict:
    sha = sha256_file(stored)
    return {
        "id": entry_id,
        "path": rel,
        "size": stored.stat().st_size,
        "sha256": sha,
        "kind": classify(rel),
        "hint": hint,
        "dup_model_id": _dup_lookup(db, sha),
    }


# ---------------------------------------------------------------- grouping


def clean_name(raw: str) -> str:
    s = PurePosixPath(raw).name
    s = re.sub(r"\.(zip|stl|3mf|obj|step|stp|ply|gcode)$", "", s, flags=re.I)
    s = re.sub(r"^\d{4,}[-_ ]+", "", s)  # Printables "763622-name"
    s = re.sub(r"[-_ ]+\d{4,}$", "", s)  # Thingiverse "name - 763622"
    s = re.sub(r"[_]+", " ", s)
    s = re.sub(r"\s*-\s*", " - ", s) if " - " in s else s.replace("-", " ")
    s = re.sub(r"\s+", " ", s).strip(" -")
    if s and s == s.lower():
        s = s[:1].upper() + s[1:]
    return s or "Untitled"


def _stem_key(path: str) -> str:
    stem = PurePosixPath(path).stem.lower()
    tokens = [t for t in re.split(r"[\s_\-.()\[\]]+", stem) if t]
    meaningful = [t for t in tokens if not t.isdigit() and t not in PART_WORDS and not re.fullmatch(r"v\d+", t)]
    if meaningful and len(meaningful[0]) >= 3:
        return meaningful[0]
    return stem


def _common_dir(paths: list[str]) -> tuple[str, ...]:
    parts = [PurePosixPath(p).parts[:-1] for p in paths]
    if not parts:
        return ()
    prefix = []
    for level in zip(*parts):
        if len(set(level)) != 1:
            break
        prefix.append(level[0])
    return tuple(prefix)


def propose_groups(files: list[dict]) -> list[dict]:
    """Return [{"name", "file_ids"}] suggestions. The client can edit before commit."""
    groups: "OrderedDict[str, dict]" = OrderedDict()

    def put(key: str, name: str, entry: dict) -> None:
        g = groups.setdefault(key, {"name": name, "file_ids": []})
        g["file_ids"].append(entry["id"])

    for e in files:
        if e["hint"].startswith("zip:"):
            put(e["hint"], clean_name(e["hint"][4:]), e)

    folder = [e for e in files if e["hint"] == "folder"]
    if folder:
        common = _common_dir([e["path"] for e in folder])
        below = {PurePosixPath(e["path"]).parts[len(common)] for e in folder if len(PurePosixPath(e["path"]).parts) > len(common) + 1}
        split = bool(below) and not all(d.lower() in GENERIC_DIRS for d in below)
        root_name = clean_name(common[-1]) if common else "Untitled"
        for e in folder:
            parts = PurePosixPath(e["path"]).parts
            if split and len(parts) > len(common) + 1 and parts[len(common)].lower() not in GENERIC_DIRS:
                sub = parts[len(common)]
                put("dir:" + "/".join(common + (sub,)), clean_name(sub), e)
            else:
                put("dir:" + "/".join(common), root_name, e)

    loose = [e for e in files if e["hint"] == "loose"]
    by_key: "OrderedDict[str, list[dict]]" = OrderedDict()
    for e in sorted(loose, key=lambda e: e["path"].lower()):
        by_key.setdefault(_stem_key(e["path"]), []).append(e)
    for key, entries in by_key.items():
        primary = next((e for e in entries if e["kind"] in ("mesh", "cad")), entries[0])
        name = clean_name(primary["path"]) if len(entries) == 1 else clean_name(key)
        for e in entries:
            put("loose:" + key, name, e)

    return list(groups.values())


def commit_batch(db: Session, batch: UploadBatch, groups: list[dict], user: User) -> list[Model]:
    """groups: [{"name", "file_ids", "category_id"?, "tags"?, "source_url"?, "skip_duplicates"?}]"""
    entries = {e["id"]: e for e in batch.files}
    base = batch_dir(batch)
    created: list[Model] = []
    for g in groups:
        chosen = [entries[i] for i in g.get("file_ids", []) if i in entries]
        if g.get("skip_duplicates"):
            chosen = [e for e in chosen if not e.get("dup_model_id")]
        if not chosen:
            continue
        model = create_model(db, g.get("name") or "Untitled", user)
        if g.get("category_id"):
            model.category_id = g["category_id"]
        if g.get("source_url"):
            model.source_url = g["source_url"][:1024]
        model.tags = get_or_create_tags(db, g.get("tags") or [])
        strip = _common_dir([e["path"] for e in chosen])
        for e in chosen:
            rel = "/".join(PurePosixPath(e["path"]).parts[len(strip):]) or PurePosixPath(e["path"]).name
            add_file(db, model, base / e["id"], rel, user)
        db.flush()
        db.refresh(model)
        apply_rules(db, model)
        # Categorised during review counts as triaged; rule-assigned categories still need a look.
        model.untriaged = not g.get("category_id")
        refresh_model(db, model)
        if model.source_url:
            enqueue(db, "import_url", model_id=model.id, url=model.source_url)
        created.append(model)
    batch.state = "committed"
    db.commit()
    shutil.rmtree(base, ignore_errors=True)
    db.delete(batch)
    db.commit()
    return created


def discard_batch(db: Session, batch: UploadBatch) -> None:
    shutil.rmtree(batch_dir(batch), ignore_errors=True)
    db.delete(batch)
    db.commit()
