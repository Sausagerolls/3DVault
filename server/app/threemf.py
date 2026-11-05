"""Streaming 3MF reader.

Slicer projects (Bambu/Orca/Prusa) can hold hundreds of MB of XML spread over
many object files. Building a full XML tree for that needs gigabytes, so this
reader streams each part with iterparse and keeps vertices in compact arrays.
It supports the core spec plus the production extension (p:path components).
"""

import posixpath
import re
import zipfile
from array import array
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from lxml import etree

P_PATH = "{http://schemas.microsoft.com/3dmanufacturing/production/2015/06}path"
MAX_FACES = 30_000_000


class ThreeMFError(Exception):
    pass


@dataclass
class _Object:
    verts: array = field(default_factory=lambda: array("f"))
    tris: array = field(default_factory=lambda: array("l"))
    # (file or None for same file, object id, 4x4 transform)
    comps: list = field(default_factory=list)
    name: str = ""


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _matrix(attr: str | None) -> np.ndarray:
    """3MF transforms are 12 numbers, row-vector convention: p' = [p 1] @ M."""
    m = np.eye(4)
    if attr:
        vals = [float(v) for v in attr.split()]
        if len(vals) == 12:
            m[:3, :3] = np.array(vals[:9]).reshape(3, 3)
            m[3, :3] = vals[9:]
    return m


def _norm(name: str) -> str:
    return posixpath.normpath(name.lstrip("/"))


def _root_model(z: zipfile.ZipFile) -> str:
    try:
        rels = z.read("_rels/.rels").decode("utf-8", "replace")
        m = re.search(r'Target="([^"]+)"[^>]*Type="[^"]*3dmodel"|Type="[^"]*3dmodel"[^>]*Target="([^"]+)"', rels)
        if m:
            return _norm(m.group(1) or m.group(2))
    except KeyError:
        pass
    return "3D/3dmodel.model"


def _parse(z: zipfile.ZipFile, name: str) -> tuple[dict[str, _Object], list]:
    objects: dict[str, _Object] = {}
    items: list = []
    cur: _Object | None = None
    with z.open(name) as fh:
        for event, el in etree.iterparse(fh, events=("start", "end"), huge_tree=True):
            tag = _local(el.tag)
            if event == "start":
                if tag == "object":
                    cur = _Object(name=el.get("name") or "")
                    objects[el.get("id")] = cur
                continue
            if tag == "vertex" and cur is not None:
                a = el.attrib
                cur.verts.extend((float(a["x"]), float(a["y"]), float(a["z"])))
            elif tag == "triangle" and cur is not None:
                a = el.attrib
                cur.tris.extend((int(a["v1"]), int(a["v2"]), int(a["v3"])))
            elif tag == "component" and cur is not None:
                path = el.get(P_PATH)
                cur.comps.append((_norm(path) if path else None, el.get("objectid"), _matrix(el.get("transform"))))
            elif tag == "item":
                path = el.get(P_PATH)
                items.append((_norm(path) if path else None, el.get("objectid"), _matrix(el.get("transform"))))
            elif tag == "object":
                cur = None
            else:
                continue
            # Free parsed elements so memory stays flat.
            el.clear(keep_tail=False)
            while el.getprevious() is not None:
                del el.getparent()[0]
    return objects, items


def _plates(z: zipfile.ZipFile) -> tuple[list[dict], dict[tuple[str, int], int], dict[str, str]]:
    """From a Bambu or Orca project: its plates, which plate each object instance is on, and
    object names. A plain 3MF has none of these."""
    try:
        root = etree.fromstring(z.read("Metadata/model_settings.config"))
    except (KeyError, etree.XMLSyntaxError):
        return [], {}, {}
    names = {}
    for obj in root.findall("object"):
        for m in obj.findall("metadata"):
            if m.get("key") == "name" and m.get("value"):
                names[obj.get("id")] = m.get("value")
    plates, where = [], {}
    for plate in root.findall("plate"):
        meta = {m.get("key"): m.get("value") for m in plate.findall("metadata")}
        try:
            index = int(meta.get("plater_id") or len(plates) + 1)
        except ValueError:
            index = len(plates) + 1
        plates.append({"index": index, "name": meta.get("plater_name") or ""})
        for inst in plate.findall("model_instance"):
            m = {x.get("key"): x.get("value") for x in inst.findall("metadata")}
            try:
                where[(m.get("object_id"), int(m.get("instance_id") or 0))] = index
            except ValueError:
                pass
    return plates, where, names


def read_scene(path: Path, write_object) -> dict:
    """Read a 3MF as separate objects, placed on their plates.

    write_object(number, vertices, faces) receives each object once, in its own coordinates, so
    big projects needn't all be in memory at once. Returns {plates, objects, items}, where an item
    is a copy of an object on a plate, and its matrix is 16 numbers by column.
    """
    try:
        z = zipfile.ZipFile(path)
    except zipfile.BadZipFile as e:
        raise ThreeMFError("Not a valid 3MF (zip) file") from e
    with z:
        root = _root_model(z)
        plates, where, names = _plates(z)
        files: dict[str, dict[str, _Object]] = {}

        def objects_in(name: str) -> dict[str, _Object]:
            if name not in files:
                if name not in z.namelist():
                    raise ThreeMFError(f"Missing part {name}")
                files[name] = _parse(z, name)[0]
            return files[name]

        root_objects, build = _parse(z, root)
        files[root] = root_objects
        if not build:
            build = [(None, oid, np.eye(4)) for oid, o in root_objects.items() if len(o.tris)]

        numbers: dict[tuple[str, str], int] = {}
        objects: list[dict] = []
        items: list[dict] = []
        seen: dict[str, int] = {}
        for ipath, oid, m in build:
            key = (ipath or root, oid)
            if key not in numbers:
                out_v: list[np.ndarray] = []
                out_f: list[np.ndarray] = []
                count = [0, 0]

                def emit(name: str, object_id: str, t: np.ndarray, depth: int = 0) -> None:
                    if depth > 16:
                        raise ThreeMFError("Component nesting too deep")
                    obj = objects_in(name).get(object_id)
                    if obj is None:
                        return
                    if len(obj.tris):
                        v = np.frombuffer(obj.verts, dtype=np.float32).reshape(-1, 3).astype(np.float64)
                        f = np.frombuffer(obj.tris, dtype=np.int64 if obj.tris.itemsize == 8 else np.int32).reshape(-1, 3)
                        out_v.append(v @ t[:3, :3] + t[3, :3])
                        out_f.append(f.astype(np.int64) + count[0])
                        count[0] += len(v)
                        count[1] += len(f)
                        if count[1] > MAX_FACES:
                            raise ThreeMFError(f"An object has more than {MAX_FACES:,} triangles")
                    for cpath, cid, cm in obj.comps:
                        emit(cpath or name, cid, cm @ t, depth + 1)

                emit(key[0], oid, np.eye(4))
                if not out_f:
                    continue
                number = len(objects)
                numbers[key] = number
                top = objects_in(key[0]).get(oid)
                objects.append({"object": number, "name": names.get(oid) or (top.name if top else "") or f"Object {number + 1}"})
                write_object(number, np.concatenate(out_v), np.concatenate(out_f))
                del out_v, out_f
                # Slicers keep each object in its own file, which isn't needed again.
                for name in [n for n in files if n != root]:
                    del files[name]
            instance = seen.get(oid, 0)
            seen[oid] = instance + 1
            items.append({
                "object": numbers[key],
                "plate": where.get((oid, instance), plates[0]["index"] if plates else 1),
                "matrix": [float(x) for x in m.flatten()],
            })
    if not objects:
        raise ThreeMFError("File contains no triangle mesh")
    return {"plates": plates or [{"index": 1, "name": ""}], "objects": objects, "items": items}


def load(path: Path) -> tuple[np.ndarray, np.ndarray, list[list[float]]]:
    """Return (vertices float32 Nx3, faces int64 Mx3, per-build-item extents) for the whole build."""
    try:
        z = zipfile.ZipFile(path)
    except zipfile.BadZipFile as e:
        raise ThreeMFError("Not a valid 3MF (zip) file") from e
    with z:
        root = _root_model(z)
        files: dict[str, dict[str, _Object]] = {}

        def objects_in(name: str) -> dict[str, _Object]:
            if name not in files:
                if name not in z.namelist():
                    raise ThreeMFError(f"Missing part {name}")
                files[name] = _parse(z, name)[0]
            return files[name]

        root_objects, items = _parse(z, root)
        files[root] = root_objects
        if not items:  # no build section: show every object that has geometry
            items = [(None, oid, np.eye(4)) for oid, o in root_objects.items() if len(o.tris)]

        out_v: list[np.ndarray] = []
        out_f: list[np.ndarray] = []
        count = [0, 0]  # vertices, faces so far

        def emit(name: str, oid: str, m: np.ndarray, depth: int = 0) -> None:
            if depth > 16:
                raise ThreeMFError("Component nesting too deep")
            obj = objects_in(name).get(oid)
            if obj is None:
                return
            if len(obj.tris):
                v = np.frombuffer(obj.verts, dtype=np.float32).reshape(-1, 3).astype(np.float64)
                v = (v @ m[:3, :3] + m[3, :3]).astype(np.float32)
                f = np.frombuffer(obj.tris, dtype=np.int64 if obj.tris.itemsize == 8 else np.int32).reshape(-1, 3)
                out_v.append(v)
                out_f.append(f.astype(np.int64) + count[0])
                count[0] += len(v)
                count[1] += len(f)
                if count[1] > MAX_FACES:
                    raise ThreeMFError(f"Model has more than {MAX_FACES:,} triangles")
            for cpath, cid, cm in obj.comps:
                emit(cpath or name, cid, cm @ m, depth + 1)

        parts: list[list[float]] = []
        for ipath, oid, m in items:
            first = len(out_v)
            emit(ipath or root, oid, m)
            if len(out_v) > first:
                pts = np.concatenate(out_v[first:])
                parts.append([round(float(x), 2) for x in pts.max(axis=0) - pts.min(axis=0)])

    if not out_f:
        raise ThreeMFError("File contains no triangle mesh")
    return np.concatenate(out_v), np.concatenate(out_f), parts
