"""Meshes and projects for the 3D plate editor.

The editor shows a refined copy of each file, where long edges are split so that support
painting isn't limited to the file's own large triangles. The browser paints whole triangles of
that copy, and the server rebuilds the same copy to write them into a project for OrcaSlicer,
so triangle numbers always match.
"""

import json
import threading
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

import numpy as np
import trimesh

from .config import settings
from .formats import file_ext
from .mesh import MeshError, cluster, decimate, load_mesh
from .threemf import ThreeMFError, read_scene

MAX_FACES = 1_500_000
MIN_EDGE_MM = 1.0
# Bump when the refinement changes, so old copies aren't matched against new triangle numbers.
VERSION = 2
# Denser objects are shown as a lighter copy, so that a big plate stays usable in a browser.
DISPLAY_FACES = 300_000
CACHE_LIMIT = 30 * 1024**3

# OrcaSlicer's triangle paint values, as written in a 3MF's paint_supports attribute.
ENFORCER = "4"
BLOCKER = "8"


def refine(vertices: np.ndarray, faces: np.ndarray, max_edge: float, max_faces: int = MAX_FACES) -> tuple[np.ndarray, np.ndarray]:
    """Split edges longer than max_edge at their middle until none are left, or max_faces is near.

    A split is decided per edge, so both triangles sharing an edge agree on it. That keeps a
    closed mesh closed, without the cracks that splitting whole triangles leaves.
    """
    v, f = np.asarray(vertices, dtype=np.float64), np.asarray(faces, dtype=np.int64)
    while True:
        corner_edges = np.sort(f[:, [0, 1, 1, 2, 2, 0]].reshape(-1, 2), axis=1)
        edges, inverse = np.unique(corner_edges, axis=0, return_inverse=True)
        inverse = inverse.reshape(-1, 3)
        long = np.linalg.norm(v[edges[:, 0]] - v[edges[:, 1]], axis=1) > max_edge
        if not long.any():
            return v, f
        split = long[inverse]
        # One split adds one triangle, so this is the exact size of the next round.
        if len(f) + int(split.sum()) > max_faces:
            return v, f
        mid_of_edge = np.full(len(edges), -1, dtype=np.int64)
        mid_of_edge[long] = len(v) + np.arange(int(long.sum()))
        v = np.vstack([v, (v[edges[long, 0]] + v[edges[long, 1]]) / 2])
        m = mid_of_edge[inverse]
        a, b, c = f[:, 0], f[:, 1], f[:, 2]
        ab, bc, ca = m[:, 0], m[:, 1], m[:, 2]
        pattern = split[:, 0] * 1 + split[:, 1] * 2 + split[:, 2] * 4
        layouts = {
            0: [(a, b, c)],
            1: [(a, ab, c), (ab, b, c)],
            2: [(a, b, bc), (a, bc, c)],
            4: [(a, b, ca), (b, c, ca)],
            3: [(ab, b, bc), (a, ab, bc), (a, bc, c)],
            6: [(bc, c, ca), (a, b, bc), (a, bc, ca)],
            5: [(a, ab, ca), (ab, b, c), (ab, c, ca)],
            7: [(a, ab, ca), (ab, b, bc), (bc, c, ca), (ab, bc, ca)],
        }
        # Keep children next to each other in the order of their parents, so the result only
        # depends on the input.
        parents, parts = [], []
        for p, tris in layouts.items():
            pick = np.where(pattern == p)[0]
            for t in tris:
                parents.append(pick)
                parts.append(np.column_stack([t[0][pick], t[1][pick], t[2][pick]]))
        f = np.vstack(parts)[np.argsort(np.concatenate(parents), kind="stable")]


def _base(source: Path, file_id: int) -> str:
    stat = source.stat()
    return f"editor-{file_id}-{stat.st_size}-{int(stat.st_mtime)}-v{VERSION}"


def _store_object(base: str, number: int, vertices: np.ndarray, faces: np.ndarray) -> int:
    """Save an object's refined mesh for slicing, and a lighter copy to show if it's very dense."""
    mesh = trimesh.Trimesh(vertices, faces, process=False)
    mesh.merge_vertices()
    diagonal = float(np.linalg.norm(mesh.extents))
    v, f = refine(mesh.vertices, mesh.faces, max(MIN_EDGE_MM, diagonal / 120))
    full = trimesh.Trimesh(v, f, process=False)
    _write_stl(full, settings.cache_dir / f"{base}-{number}.stl")
    if len(f) > DISPLAY_FACES:
        # Quadric decimation keeps the shape best, but needs memory the densest objects can't spare.
        light = decimate(full, DISPLAY_FACES) if len(f) < 8_000_000 else cluster(full, DISPLAY_FACES)
        _write_stl(light, settings.cache_dir / f"{base}-{number}-light.stl")
    return len(f)


def _write_stl(mesh: trimesh.Trimesh, out: Path) -> None:
    tmp = out.with_suffix(".tmp")
    mesh.export(tmp, file_type="stl")
    tmp.replace(out)


_locks: dict[int, threading.Lock] = {}
_locks_guard = threading.Lock()


def _trim_cache() -> None:
    """Forget the least recently opened files' meshes once they take up too much disk."""
    groups: dict[str, list[Path]] = {}
    for path in settings.cache_dir.glob("editor-*"):
        groups.setdefault(path.name.split("-")[1], []).append(path)
    newest_first = sorted(groups.values(), key=lambda files: -max(f.stat().st_mtime for f in files))
    total = 0
    for files in newest_first:
        total += sum(f.stat().st_size for f in files)
        if total > CACHE_LIMIT:
            for f in files:
                f.unlink(missing_ok=True)


def editor_scene(source: Path, file_id: int) -> dict:
    """A file's plates, objects and their placement, built once and then kept in the cache."""
    with _locks_guard:
        lock = _locks.setdefault(file_id, threading.Lock())
    # A big project takes minutes, so a page reload meanwhile waits rather than starting again.
    with lock:
        return _build_scene(source, file_id)


def _build_scene(source: Path, file_id: int) -> dict:
    base = _base(source, file_id)
    index = settings.cache_dir / f"{base}.json"
    if index.exists():
        index.touch()
        return json.loads(index.read_text())
    for old in settings.cache_dir.glob(f"editor-{file_id}-*"):
        old.unlink(missing_ok=True)
    if file_ext(source.name) == "3mf":
        try:
            scene = read_scene(source, lambda number, v, f: _store_object(base, number, v, f))
        except ThreeMFError as e:
            raise MeshError(str(e)) from e
    else:
        mesh = load_mesh(source)
        _store_object(base, 0, mesh.vertices, mesh.faces)
        scene = {"plates": [{"index": 1, "name": ""}], "objects": [{"object": 0, "name": source.name}], "items": [{"object": 0, "plate": 1, "matrix": None}]}
    tmp = index.with_suffix(".tmp")
    tmp.write_text(json.dumps(scene))
    tmp.replace(index)
    _trim_cache()
    return scene


def object_paths(source: Path, file_id: int, number: int) -> tuple[Path, Path]:
    """An object's mesh for slicing and the one to show, which are the same unless it's dense."""
    editor_scene(source, file_id)
    base = _base(source, file_id)
    full = settings.cache_dir / f"{base}-{number}.stl"
    if not full.exists():
        raise MeshError("That object isn't in this file")
    light = settings.cache_dir / f"{base}-{number}-light.stl"
    return full, light if light.exists() else full


def _load_stl(path: Path) -> trimesh.Trimesh:
    mesh = trimesh.load(path, file_type="stl", process=False)
    mesh.merge_vertices()
    return mesh


def transfer_paint(light: trimesh.Trimesh, full: trimesh.Trimesh, painted: np.ndarray) -> np.ndarray:
    """Painted triangles of a lighter copy, as triangles of the full mesh: those in a small cell
    around painted ones and facing the same way."""
    if not len(painted):
        return painted
    size = max(float(np.sqrt(np.median(light.area_faces[painted]))) * 1.5, 1e-3)
    origin = light.triangles_center[painted].min(axis=0)
    cells = np.floor((light.triangles_center[painted] - origin) / size).astype(np.int64)
    normals = {}
    for cell, normal in zip(map(tuple, cells.tolist()), light.face_normals[painted]):
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    key = (cell[0] + dx, cell[1] + dy, cell[2] + dz)
                    normals[key] = normals.get(key, 0) + normal
    centres = np.floor((full.triangles_center - origin) / size).astype(np.int64)
    out = [
        i for i, (cell, normal) in enumerate(zip(map(tuple, centres.tolist()), full.face_normals))
        if cell in normals and float(np.dot(normals[cell], normal)) > 0
    ]
    return np.asarray(out, dtype=np.int64)


def expand_runs(runs: list[int], face_count: int) -> np.ndarray:
    """[start, count, start, count, ...] to triangle numbers. Out of range numbers are dropped."""
    if not runs:
        return np.empty(0, dtype=np.int64)
    pairs = np.asarray(runs, dtype=np.int64).reshape(-1, 2)
    picked = [np.arange(s, s + n) for s, n in pairs if n > 0]
    if not picked:
        return np.empty(0, dtype=np.int64)
    out = np.concatenate(picked)
    return out[(out >= 0) & (out < face_count)]


def _transform(matrix: list[float]) -> str:
    # The editor sends a 4x4 matrix by column. A 3MF transform lists the same numbers by column,
    # leaving out the bottom row.
    e = matrix
    return " ".join(f"{float(x):.6f}" for x in (e[0], e[1], e[2], e[4], e[5], e[6], e[8], e[9], e[10], e[12], e[13], e[14]))


def write_project(items: list[dict], out: Path) -> None:
    """Write placed meshes to a 3MF. Each item is {path, light, matrix, enforce, block}, where
    painting is in triangles of `light`, the mesh the editor showed, if that differs from `path`.

    Leaving out Bambu Studio's application tag on purpose: OrcaSlicer then reads this as a plain
    3MF, whereas a Bambu tagged project with no plate settings crashes it.
    """
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=1) as z:
        z.writestr("[Content_Types].xml", (
            '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>'))
        z.writestr("_rels/.rels", (
            '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>'))
        with z.open("3D/3dmodel.model", "w", force_zip64=True) as raw:
            def w(text: str) -> None:
                raw.write(text.encode())

            w('<?xml version="1.0" encoding="UTF-8"?>\n<model unit="millimeter" xml:lang="en-US" '
              'xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources>')
            for n, item in enumerate(items, 1):
                mesh = _load_stl(item["path"])
                enforce, block = item.get("enforce") or [], item.get("block") or []
                shown = item.get("light")
                if shown and shown != item["path"] and (enforce or block):
                    light = _load_stl(shown)
                    enforced = transfer_paint(light, mesh, expand_runs(enforce, len(light.faces)))
                    blocked = transfer_paint(light, mesh, expand_runs(block, len(light.faces)))
                else:
                    enforced = expand_runs(enforce, len(mesh.faces))
                    blocked = expand_runs(block, len(mesh.faces))
                paint = dict.fromkeys(enforced.tolist(), ENFORCER)
                paint.update(dict.fromkeys(blocked.tolist(), BLOCKER))
                w(f'<object id="{n}" type="model" name="{escape(str(item.get("name") or n), {chr(34): "&quot;"})}"><mesh><vertices>')
                w("".join(f'<vertex x="{x:.5f}" y="{y:.5f}" z="{z_:.5f}"/>' for x, y, z_ in mesh.vertices.tolist()))
                w("</vertices><triangles>")
                w("".join(
                    f'<triangle v1="{a}" v2="{b}" v3="{c}"' + (f' paint_supports="{paint[i]}"/>' if i in paint else "/>")
                    for i, (a, b, c) in enumerate(mesh.faces.tolist())))
                w("</triangles></mesh></object>")
            w("</resources><build>")
            for n, item in enumerate(items, 1):
                w(f'<item objectid="{n}" transform="{_transform(item["matrix"])}" printable="1"/>')
            w("</build></model>")
