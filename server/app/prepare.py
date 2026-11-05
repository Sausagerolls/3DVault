"""Meshes and projects for the 3D plate editor.

The editor shows a refined copy of each file, where long edges are split so that support
painting isn't limited to the file's own large triangles. The browser paints whole triangles of
that copy, and the server rebuilds the same copy to write them into a project for OrcaSlicer,
so triangle numbers always match.
"""

import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

import numpy as np
import trimesh

from .config import settings
from .mesh import load_mesh

MAX_FACES = 1_500_000
MIN_EDGE_MM = 1.0
# Bump when the refinement changes, so old copies aren't matched against new triangle numbers.
VERSION = 1

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


def editor_mesh_path(source: Path, file_id: int) -> Path:
    """The refined copy of a model file as a binary STL, built once and then kept in the cache."""
    stat = source.stat()
    out = settings.cache_dir / f"editor-{file_id}-{stat.st_size}-{int(stat.st_mtime)}-v{VERSION}.stl"
    if out.exists():
        return out
    for old in settings.cache_dir.glob(f"editor-{file_id}-*.stl"):
        old.unlink(missing_ok=True)
    mesh = load_mesh(source)
    mesh.merge_vertices()
    diagonal = float(np.linalg.norm(mesh.extents))
    v, f = refine(mesh.vertices, mesh.faces, max(MIN_EDGE_MM, diagonal / 120))
    tmp = out.with_suffix(".tmp")
    trimesh.Trimesh(v, f, process=False).export(tmp, file_type="stl")
    tmp.replace(out)
    return out


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
    """Write placed meshes to a 3MF. Each item is {path, matrix, enforce, block}.

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
                mesh = trimesh.load(item["path"], file_type="stl", process=False)
                mesh.merge_vertices()
                paint = dict.fromkeys(expand_runs(item.get("enforce") or [], len(mesh.faces)).tolist(), ENFORCER)
                paint.update(dict.fromkeys(expand_runs(item.get("block") or [], len(mesh.faces)).tolist(), BLOCKER))
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
