"""Heavy per-file processing. Run in a child process so a crash in a mesh/CAD
library or a runaway file cannot take down the worker."""

import sys

from .db import init_engine, session_scope
from .formats import embedded_thumbnail, gcode_metadata, is_slicer_project
from .library import file_path, preview_path, thumb_path
from .models import File


def process_file(file_id: int) -> None:
    from . import mesh as meshlib

    with session_scope() as db:
        f = db.get(File, file_id)
        if f is None:
            return
        path = file_path(f)
        meta = dict(f.meta or {})
        errors = []

        if f.kind in ("mesh", "cad"):
            if f.ext == "3mf" and is_slicer_project(path):
                meta["slicer_project"] = True
            try:
                m = meshlib.load_mesh(path)
                stats = meshlib.analyse(m)
                f.size_x, f.size_y, f.size_z = stats["size_x"], stats["size_y"], stats["size_z"]
                f.tri_count = stats["tri_count"]
                if stats.get("parts"):
                    meta["parts"] = stats["parts"]
                # Decimate the full mesh once and derive smaller versions from that to bound memory.
                m = meshlib.decimate(m, meshlib.DISPLAY_FACES)
                meshlib.export_glb(m, preview_path(f.id), meshlib.DISPLAY_FACES)
                meshlib.export_glb(m, preview_path(f.id, lod=True), meshlib.LOD_FACES)
                f.has_preview = True
                meshlib.render_thumbnail(m, thumb_path(f.id))
                f.has_thumb = True
            except Exception as e:  # keep going: an embedded thumbnail may still exist
                errors.append(str(e))
            if not f.has_thumb and f.ext == "3mf":
                data = embedded_thumbnail(path)
                if data:
                    meshlib.image_thumbnail(data, thumb_path(f.id))
                    f.has_thumb = True
        elif f.kind == "gcode":
            meta.update(gcode_metadata(path))
            data = embedded_thumbnail(path)
            if data:
                try:
                    meshlib.image_thumbnail(data, thumb_path(f.id))
                    f.has_thumb = True
                except Exception as e:
                    errors.append(f"thumbnail: {e}")
        elif f.kind in ("image", "photo"):
            try:
                meshlib.image_thumbnail(path, thumb_path(f.id))
                f.has_thumb = True
            except Exception as e:
                errors.append(f"image: {e}")

        f.meta = meta
        f.error = "; ".join(errors)
        f.status = "error" if errors and not (f.has_thumb or f.has_preview) else "ready"


if __name__ == "__main__":
    init_engine()
    if sys.argv[1] == "process_file":
        process_file(int(sys.argv[2]))
