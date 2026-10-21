"""Mesh loading, analysis, preview export and CPU thumbnail rendering."""

import io
import tempfile
from pathlib import Path

import numpy as np
import trimesh
from PIL import Image, ImageDraw

from .formats import CAD_EXTS, file_ext

DISPLAY_FACES = 400_000
# Hover previews. Version 1 used 15k faces, which made detailed models unrecognisable.
LOD_FACES = 100_000
LOD_VERSION = 2
RENDER_FACES = 80_000
BASE_COLOR = np.array([240, 140, 58], dtype=float)  # warm PLA orange


class MeshError(Exception):
    pass


def load_mesh(path: Path) -> trimesh.Trimesh:
    ext = file_ext(path.name)
    if ext in CAD_EXTS:
        return _load_step(path)
    if ext == "3mf":
        from .threemf import ThreeMFError, load

        try:
            v, f, parts = load(path)
            mesh = trimesh.Trimesh(v, f, process=False)
            # Build items print as separate parts; slicer projects spread them over several plates.
            mesh.metadata["parts"] = parts
            return mesh
        except ThreeMFError as e:
            raise MeshError(str(e)) from e
    try:
        loaded = trimesh.load(str(path), force="scene", process=False)
    except Exception as e:
        raise MeshError(f"Could not read {ext.upper()}: {e}") from e
    if isinstance(loaded, trimesh.Scene):
        if not loaded.geometry:
            raise MeshError("File contains no geometry")
        mesh = loaded.to_geometry() if hasattr(loaded, "to_geometry") else loaded.dump(concatenate=True)
    else:
        mesh = loaded
    if not isinstance(mesh, trimesh.Trimesh) or len(mesh.faces) == 0:
        raise MeshError("File contains no triangle mesh")
    return mesh


def _load_step(path: Path) -> trimesh.Trimesh:
    try:
        from OCP.Bnd import Bnd_Box
        from OCP.BRepBndLib import BRepBndLib
        from OCP.BRepMesh import BRepMesh_IncrementalMesh
        from OCP.IFSelect import IFSelect_RetDone
        from OCP.StlAPI import StlAPI_Writer
        from OCP.STEPControl import STEPControl_Reader
    except ImportError as e:
        raise MeshError("STEP support is not installed in this image") from e

    reader = STEPControl_Reader()
    if reader.ReadFile(str(path)) != IFSelect_RetDone:
        raise MeshError("Could not read STEP file")
    reader.TransferRoots()
    shape = reader.OneShape()
    box = Bnd_Box()
    BRepBndLib.Add_s(shape, box)
    lo, hi = box.CornerMin(), box.CornerMax()
    diag = float(np.linalg.norm([hi.X() - lo.X(), hi.Y() - lo.Y(), hi.Z() - lo.Z()])) or 1.0
    BRepMesh_IncrementalMesh(shape, max(diag * 0.0008, 0.005), False, 0.3, True)
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "step.stl"
        writer = StlAPI_Writer()
        writer.ASCIIMode = False
        if not writer.Write(shape, str(out)):
            raise MeshError("STEP tessellation failed")
        mesh = trimesh.load(str(out), force="mesh")
    if len(mesh.faces) == 0:
        raise MeshError("STEP file has no solid geometry")
    return mesh


def analyse(mesh: trimesh.Trimesh) -> dict:
    parts = mesh.metadata.get("parts") or []
    if len(parts) > 1:
        # Report the biggest printable part, not the plate layout.
        ext = max(parts, key=lambda p: p[0] * p[1] * p[2])
        return {
            "size_x": ext[0], "size_y": ext[1], "size_z": ext[2],
            "tri_count": int(len(mesh.faces)),
            "parts": parts,
        }
    ext = mesh.extents
    return {
        "size_x": round(float(ext[0]), 2),
        "size_y": round(float(ext[1]), 2),
        "size_z": round(float(ext[2]), 2),
        "tri_count": int(len(mesh.faces)),
    }


def cluster(mesh: trimesh.Trimesh, max_faces: int) -> trimesh.Trimesh:
    """Cheap vertex-clustering reduction. Needs far less memory than quadric decimation,
    so huge meshes are brought down with this first."""
    v = np.asarray(mesh.vertices, dtype=np.float32)
    f = np.asarray(mesh.faces)
    extent = float((v.max(axis=0) - v.min(axis=0)).max()) or 1.0
    cell = extent / 2000
    for _ in range(8):
        keys = np.floor((v - v.min(axis=0)) / cell).astype(np.int64)
        uniq, inverse = np.unique(keys, axis=0, return_inverse=True)
        nf = inverse.reshape(-1)[f]
        keep = (nf[:, 0] != nf[:, 1]) & (nf[:, 1] != nf[:, 2]) & (nf[:, 0] != nf[:, 2])
        if keep.sum() <= max_faces * 1.2 or cell > extent / 50:
            break
        cell *= 1.5
    counts = np.bincount(inverse.reshape(-1), minlength=len(uniq)).astype(np.float32)
    centres = np.zeros((len(uniq), 3), dtype=np.float32)
    np.add.at(centres, inverse.reshape(-1), v)
    centres /= counts[:, None]
    return trimesh.Trimesh(centres, nf[keep], process=False)


def decimate(mesh: trimesh.Trimesh, max_faces: int) -> trimesh.Trimesh:
    if len(mesh.faces) <= max_faces:
        return mesh
    import fast_simplification

    if len(mesh.faces) > 1_500_000:
        mesh = cluster(mesh, 1_000_000)
        if len(mesh.faces) <= max_faces:
            return mesh

    reduction = 1.0 - max_faces / len(mesh.faces)
    v, f = fast_simplification.simplify(
        np.asarray(mesh.vertices, dtype=np.float32),
        np.asarray(mesh.faces, dtype=np.int64),
        target_reduction=min(reduction, 0.995),
    )
    return trimesh.Trimesh(v, f, process=False)


def export_glb(mesh: trimesh.Trimesh, out: Path, max_faces: int) -> None:
    m = decimate(mesh, max_faces)
    # Centre on the bed origin so the client viewer can frame it without recomputing.
    m = m.copy()
    m.apply_translation(-m.bounds.mean(axis=0) * [1, 1, 0] - [0, 0, m.bounds[0][2]])
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".tmp")
    tmp.write_bytes(m.export(file_type="glb"))
    tmp.replace(out)


def build_lod(full: Path, out: Path) -> None:
    """Derive the hover preview from the stored full preview, for files processed before LOD_VERSION."""
    export_glb(trimesh.load(full, force="mesh"), out, LOD_FACES)


def render_thumbnail(mesh: trimesh.Trimesh, out: Path, size: int = 512) -> None:
    """Flat-shaded orthographic render using a painter's algorithm. No GPU or GL needed."""
    m = decimate(mesh, RENDER_FACES)
    verts = np.asarray(m.vertices, dtype=float)
    faces = np.asarray(m.faces)
    verts = verts - (verts.min(axis=0) + verts.max(axis=0)) / 2

    # Camera: 35° azimuth from front-right, 28° elevation, Z-up world.
    az, el = np.radians(-35), np.radians(28)
    rz = np.array([[np.cos(az), -np.sin(az), 0], [np.sin(az), np.cos(az), 0], [0, 0, 1]])
    # Map world (x, y, z) to view (right, up, toward-camera) and tilt down.
    to_view = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]])
    rx = np.array([[1, 0, 0], [0, np.cos(el), -np.sin(el)], [0, np.sin(el), np.cos(el)]])
    v = verts @ (rx @ to_view @ rz).T

    tri = v[faces]
    normals = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    lengths = np.linalg.norm(normals, axis=1)
    keep = lengths > 0
    normals = normals[keep] / lengths[keep, None]
    tri = tri[keep]
    # Many printable meshes have inconsistent winding, so shade both sides.
    normals = normals * np.sign(normals[:, 2:3] + 1e-9)

    key = np.array([-0.4, 0.6, 0.7])
    key /= np.linalg.norm(key)
    fill = np.array([0.6, -0.2, 0.75])
    fill /= np.linalg.norm(fill)
    shade = 0.28 + 0.62 * np.clip(normals @ key, 0, 1) + 0.18 * np.clip(normals @ fill, 0, 1)
    shade += 0.12 * (1 - normals[:, 2]) ** 3  # rim light on silhouettes
    colors = np.clip(BASE_COLOR[None, :] * shade[:, None], 0, 255).astype(np.uint8)

    ss = size * 2
    xy = tri[:, :, :2]
    lo = xy.reshape(-1, 2).min(axis=0)
    hi = xy.reshape(-1, 2).max(axis=0)
    scale = 0.86 * ss / max(float((hi - lo).max()), 1e-6)
    centre = (lo + hi) / 2
    px = (xy - centre) * scale
    px[:, :, 1] *= -1
    px += ss / 2

    order = np.argsort(tri[:, :, 2].mean(axis=1))  # far to near
    img = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    for i in order:
        c = tuple(int(x) for x in colors[i]) + (255,)
        draw.polygon([tuple(p) for p in px[i]], fill=c, outline=c)
    img = img.resize((size, size), Image.LANCZOS)
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, "WEBP", quality=88)


def image_thumbnail(data_or_path, out: Path, size: int = 512) -> None:
    src = data_or_path if isinstance(data_or_path, (str, Path)) else io.BytesIO(data_or_path)
    with Image.open(src) as im:
        im = im.convert("RGBA")
        im.thumbnail((size, size), Image.LANCZOS)
        out.parent.mkdir(parents=True, exist_ok=True)
        im.save(out, "WEBP", quality=85)
