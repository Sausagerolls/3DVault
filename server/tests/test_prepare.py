"""Run with: server/.venv/bin/python server/tests/test_prepare.py"""

import sys
import tempfile
import zipfile
from pathlib import Path
from xml.etree import ElementTree

import numpy as np
import trimesh

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app import prepare  # noqa: E402


def test_refine_keeps_a_closed_mesh_closed():
    box = trimesh.creation.box((100, 30, 5))
    v, f = prepare.refine(box.vertices, box.faces, 2.0)
    out = trimesh.Trimesh(v, f, process=False)
    out.merge_vertices()
    assert len(f) > 1000
    assert out.is_watertight
    assert out.is_winding_consistent
    assert abs(out.volume - box.volume) < 1e-6
    assert np.linalg.norm(v[f[:, 0]] - v[f[:, 1]], axis=1).max() <= 2.0


def test_refine_is_repeatable_and_respects_the_limit():
    box = trimesh.creation.box((100, 100, 100))
    a = prepare.refine(box.vertices, box.faces, 5.0)
    b = prepare.refine(box.vertices, box.faces, 5.0)
    assert np.array_equal(a[1], b[1])
    _, f = prepare.refine(box.vertices, box.faces, 0.5, max_faces=5000)
    assert len(f) <= 5000


def test_expand_runs_drops_out_of_range():
    assert prepare.expand_runs([2, 3, 8, 5], 10).tolist() == [2, 3, 4, 8, 9]
    assert prepare.expand_runs([], 10).tolist() == []


def test_project_holds_transform_and_paint():
    with tempfile.TemporaryDirectory() as tmp:
        stl = Path(tmp) / "m.stl"
        trimesh.creation.box((10, 10, 10)).export(stl)
        out = Path(tmp) / "p.3mf"
        matrix = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 40, 50, 5, 1]
        prepare.write_project([{"path": stl, "matrix": matrix, "enforce": [0, 2], "block": [5, 1], "name": 'a"b'}], out)
        root = ElementTree.fromstring(zipfile.ZipFile(out).read("3D/3dmodel.model"))
    ns = {"m": "http://schemas.microsoft.com/3dmanufacturing/core/2015/02"}
    tris = root.findall(".//m:triangle", ns)
    assert [t.get("paint_supports") for t in tris[:6]] == ["4", "4", None, None, None, "8"]
    assert root.find(".//m:item", ns).get("transform").split()[-3:] == ["40.000000", "50.000000", "5.000000"]


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
