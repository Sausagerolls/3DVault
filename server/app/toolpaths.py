"""Layer-by-layer toolpaths from sliced G-code, for the print preview.

The G-code of one plate is parsed once into arrays and cached in the data folder. Clients
then ask for one layer at a time as polylines grouped by feature (walls, infill, support...).
"""

import re
import zipfile
from pathlib import Path

import numpy as np

from .config import settings

FEATURES = ["outer_wall", "inner_wall", "sparse_infill", "solid_infill", "top", "bottom", "support", "bridge", "other"]
_FEATURE_IDS = [
    ("outer wall", 0), ("overhang wall", 0), ("inner wall", 1), ("sparse infill", 2),
    ("internal solid infill", 3), ("solid infill", 3), ("top surface", 4), ("bottom surface", 5),
    ("support", 6), ("bridge", 7),
]
_WORD = re.compile(r"([XYZEF])(-?\d*\.?\d+)")


def _feature_id(name: str) -> int:
    n = name.lower()
    for key, fid in _FEATURE_IDS:
        if key in n:
            return fid
    return 8


def _cache_path(file_id: int, plate: int) -> Path:
    d = settings.cache_dir / "toolpaths"
    d.mkdir(parents=True, exist_ok=True)
    return d / f"{file_id}_{plate}.npz"


def read_gcode(path: Path, plate: int) -> str:
    if path.suffix.lower() == ".3mf":
        with zipfile.ZipFile(path) as z:
            return z.read(f"Metadata/plate_{plate}.gcode").decode(errors="replace")
    return path.read_text(errors="replace")


def parse(text: str) -> dict:
    z_list: list[float] = []
    offsets: list[int] = []
    segs: list[tuple[float, float, float, float]] = []
    feats: list[int] = []
    x = y = 0.0
    e_abs = 0.0
    relative_e = True
    feature = 8
    started = False
    for line in text.splitlines():
        if not line:
            continue
        c = line[0]
        if c == ";":
            if line.startswith("; CHANGE_LAYER") or line.startswith(";LAYER_CHANGE"):
                started = True
                offsets.append(len(segs))
                z_list.append(z_list[-1] if z_list else 0.0)
            elif line.startswith("; Z_HEIGHT:") or line.startswith(";Z:"):
                if z_list:
                    try:
                        z_list[-1] = float(line.split(":", 1)[1])
                    except ValueError:
                        pass
            elif line.startswith("; FEATURE:") or line.startswith(";TYPE:"):
                feature = _feature_id(line.split(":", 1)[1])
            continue
        if c == "M":
            if line.startswith("M83"):
                relative_e = True
            elif line.startswith("M82"):
                relative_e = False
            continue
        if c != "G":
            continue
        cmd = line.split(";", 1)[0]
        if not (cmd.startswith("G1") or cmd.startswith("G0") or cmd.startswith("G2") or cmd.startswith("G3")):
            if cmd.startswith("G92"):
                for k, v in _WORD.findall(cmd):
                    if k == "E":
                        e_abs = float(v)
            continue
        nx, ny, extrude = x, y, False
        for k, v in _WORD.findall(cmd):
            if k == "X":
                nx = float(v)
            elif k == "Y":
                ny = float(v)
            elif k == "E":
                ev = float(v)
                if relative_e:
                    extrude = ev > 0
                else:
                    extrude = ev > e_abs
                    e_abs = ev
        if started and extrude and (nx != x or ny != y):
            segs.append((x, y, nx, ny))
            feats.append(feature)
        x, y = nx, ny
    offsets.append(len(segs))
    return {
        "z": np.array(z_list, dtype=np.float32),
        "offsets": np.array(offsets, dtype=np.int64),
        "segs": np.array(segs, dtype=np.float32).reshape(-1, 4),
        "feats": np.array(feats, dtype=np.uint8),
    }


def load(file_id: int, path: Path, plate: int) -> dict:
    cache = _cache_path(file_id, plate)
    if cache.exists() and cache.stat().st_mtime >= path.stat().st_mtime:
        with np.load(cache) as data:
            return {k: data[k] for k in data.files}
    parsed = parse(read_gcode(path, plate))
    np.savez_compressed(cache, **parsed)
    return parsed


def summary(data: dict) -> dict:
    segs = data["segs"]
    bounds = None
    if len(segs):
        xs, ys = segs[:, [0, 2]], segs[:, [1, 3]]
        bounds = [float(xs.min()), float(ys.min()), float(xs.max()), float(ys.max())]
    return {"layers": len(data["z"]), "z": [round(float(z), 3) for z in data["z"]], "bounds": bounds, "features": FEATURES}


def pack(data: dict) -> bytes:
    """Every layer at once for the 3D preview, little-endian: layer count and segment count as
    uint32, then z (float32 per layer), offsets (uint32, layers + 1), segments (4 float32 each)
    and features (uint8 each), which come last to keep the rest aligned."""
    z, offsets, segs, feats = data["z"], data["offsets"], data["segs"], data["feats"]
    return b"".join((
        np.array([len(z), len(segs)], dtype="<u4").tobytes(),
        z.astype("<f4").tobytes(),
        offsets.astype("<u4").tobytes(),
        segs.astype("<f4").tobytes(),
        feats.astype("u1").tobytes(),
    ))


def layer(data: dict, index: int) -> dict:
    """One layer as polylines: consecutive segments of the same feature are joined."""
    if not 0 <= index < len(data["z"]):
        raise IndexError(index)
    a, b = int(data["offsets"][index]), int(data["offsets"][index + 1])
    segs, feats = data["segs"][a:b], data["feats"][a:b]
    paths: list[dict] = []
    cur: list[float] | None = None
    cur_f = -1
    for (x0, y0, x1, y1), f in zip(segs.tolist(), feats.tolist()):
        if cur is not None and f == cur_f and abs(cur[-2] - x0) < 1e-3 and abs(cur[-1] - y0) < 1e-3:
            cur += [round(x1, 2), round(y1, 2)]
        else:
            cur = [round(x0, 2), round(y0, 2), round(x1, 2), round(y1, 2)]
            cur_f = f
            paths.append({"f": f, "p": cur})
    return {"index": index, "z": round(float(data["z"][index]), 3), "paths": paths}
