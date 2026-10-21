"""File type detection and metadata extraction for 3D printing formats."""

import base64
import io
import re
import struct
import zipfile
from pathlib import Path

MESH_EXTS = {"stl", "obj", "ply", "3mf"}
CAD_EXTS = {"step", "stp"}
GCODE_EXTS = {"gcode", "bgcode", "ufp"}
IMAGE_EXTS = {"png", "jpg", "jpeg", "webp", "gif"}
DOC_EXTS = {"md", "txt", "pdf", "html"}
PREVIEWABLE = MESH_EXTS | CAD_EXTS


def file_ext(path: str) -> str:
    return Path(path).suffix.lower().lstrip(".")


def classify(path: str) -> str:
    ext = file_ext(path)
    name = Path(path).name.lower()
    if ext in CAD_EXTS:
        return "cad"
    if ext in GCODE_EXTS:
        return "gcode"
    if ext == "3mf":
        return "mesh"
    if ext in MESH_EXTS:
        return "mesh"
    if ext in IMAGE_EXTS:
        return "image"
    if ext in DOC_EXTS or name.startswith(("license", "readme")):
        return "doc"
    return "other"


def is_slicer_project(path: Path) -> bool:
    """True for 3MF files written by Bambu/Orca/Prusa/Cura that carry slicer settings."""
    try:
        with zipfile.ZipFile(path) as z:
            names = set(z.namelist())
    except zipfile.BadZipFile:
        return False
    return any(
        n.startswith("Metadata/") and (n.endswith(".config") or n.endswith("Slic3r_PE.config"))
        for n in names
    )


# ---------------------------------------------------------------- thumbnails


def _largest(images: list[bytes]) -> bytes | None:
    from PIL import Image

    best, best_px = None, 0
    for data in images:
        try:
            with Image.open(io.BytesIO(data)) as im:
                px = im.width * im.height
        except Exception:
            continue
        if px > best_px:
            best, best_px = data, px
    return best


def embedded_thumbnail(path: Path) -> bytes | None:
    """Return the best embedded preview image from a 3MF, G-code, bgcode or UFP file."""
    ext = file_ext(path.name)
    try:
        if ext in ("3mf", "ufp"):
            return _zip_thumbnail(path)
        if ext == "gcode":
            return _gcode_thumbnail(path)
        if ext == "bgcode":
            return _bgcode_thumbnail(path)
    except Exception:
        return None
    return None


def _zip_thumbnail(path: Path) -> bytes | None:
    with zipfile.ZipFile(path) as z:
        names = {n.lower().lstrip("/"): n for n in z.namelist()}
        # Bambu/Orca: plate_1.png is the main plate render. Prusa/Cura: thumbnail.png.
        for key in ("metadata/plate_1.png", "metadata/thumbnail.png", "metadata/thumbnail.jpg"):
            if key in names:
                return z.read(names[key])
        candidates = [
            orig
            for low, orig in names.items()
            if low.startswith("metadata/")
            and low.endswith((".png", ".jpg"))
            and not any(s in low for s in ("small", "pick_", "no_light"))
        ]
        if not candidates:
            return None
        return _largest([z.read(n) for n in candidates[:8]])


_THUMB_RE = re.compile(
    rb"; thumbnail(?:_(?:JPG|PNG|QOI))? begin \d+x\d+ \d+\s*\n(.*?); thumbnail(?:_(?:JPG|PNG|QOI))? end",
    re.S,
)


def _gcode_thumbnail(path: Path) -> bytes | None:
    # Thumbnails live in the header; 4 MB covers every slicer seen in practice.
    with open(path, "rb") as f:
        head = f.read(4 * 1024 * 1024)
    images = []
    for m in _THUMB_RE.finditer(head):
        b64 = b"".join(line.lstrip(b"; ").strip() for line in m.group(1).splitlines())
        try:
            images.append(base64.b64decode(b64))
        except Exception:
            continue
    return _largest(images)


def _bgcode_thumbnail(path: Path) -> bytes | None:
    """Parse Prusa binary G-code (libbgcode spec) and return the largest PNG/JPG thumbnail."""
    with open(path, "rb") as f:
        data = f.read(8 * 1024 * 1024)
    if data[:4] != b"GCDE":
        return None
    _, checksum_type = struct.unpack_from("<IH", data, 4)
    checksum_size = 4 if checksum_type == 1 else 0
    pos = 10
    images = []
    while pos + 8 <= len(data):
        block_type, compression, uncompressed = struct.unpack_from("<HHI", data, pos)
        pos += 8
        compressed = uncompressed
        if compression != 0:
            (compressed,) = struct.unpack_from("<I", data, pos)
            pos += 4
        param_size = 6 if block_type == 5 else 2
        params = data[pos : pos + param_size]
        pos += param_size
        payload = data[pos : pos + compressed]
        pos += compressed + checksum_size
        if block_type == 5:
            fmt = struct.unpack_from("<H", params, 0)[0]
            if fmt in (0, 1):  # PNG, JPG (QOI unsupported by Pillow)
                images.append(payload)
        elif block_type == 1:
            break  # G-code blocks follow thumbnails; stop reading.
    return _largest(images)


# ---------------------------------------------------------------- gcode metadata

_GCODE_META = [
    ("print_time", re.compile(rb";\s*estimated printing time(?: \(normal mode\))?\s*=\s*(.+)")),
    ("print_time", re.compile(rb";\s*total estimated time:\s*(.+)")),
    ("print_time_s", re.compile(rb";TIME:(\d+)")),
    ("filament_g", re.compile(rb";\s*(?:total )?filament used \[g\]\s*=\s*([\d.]+)")),
    ("filament_mm", re.compile(rb";\s*(?:total )?filament used \[mm\]\s*=\s*([\d.]+)")),
    ("filament_m", re.compile(rb";Filament used:\s*([\d.]+)m")),
    ("layer_height", re.compile(rb";\s*layer_height\s*=\s*([\d.]+)")),
    ("filament_type", re.compile(rb";\s*filament_type\s*=\s*(.+)")),
    ("printer_model", re.compile(rb";\s*printer_model\s*=\s*(.+)")),
    ("slicer", re.compile(rb"; generated by (\S+ ?[\d.]*)", re.I)),
    ("slicer", re.compile(rb";Generated with (\S+ ?[\d.]*)")),
]


def gcode_metadata(path: Path) -> dict:
    if file_ext(path.name) != "gcode":
        return {}
    size = path.stat().st_size
    chunks = []
    with open(path, "rb") as f:
        chunks.append(f.read(512 * 1024))
        if size > 1024 * 1024:
            f.seek(size - 512 * 1024)
            chunks.append(f.read())
    text = b"\n".join(chunks)
    meta: dict = {}
    for key, rx in _GCODE_META:
        if key in meta:
            continue
        m = rx.search(text)
        if m:
            meta[key] = m.group(1).decode(errors="replace").strip()
    if "print_time_s" in meta and "print_time" not in meta:
        s = int(meta.pop("print_time_s"))
        meta["print_time"] = f"{s // 3600}h {s % 3600 // 60}m"
    else:
        meta.pop("print_time_s", None)
    return meta
