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


def test_paint_transfers_to_the_full_mesh():
    box = trimesh.creation.box((40, 40, 40))
    v, f = prepare.refine(box.vertices, box.faces, 1.0)
    full = trimesh.Trimesh(v, f, process=False)
    v, f = prepare.refine(box.vertices, box.faces, 5.0)
    light = trimesh.Trimesh(v, f, process=False)
    painted = np.where(np.isclose(light.triangles_center[:, 2], -20) & (light.triangles_center[:, 0] < 0))[0]
    out = prepare.transfer_paint(light, full, painted)
    centres = full.triangles_center[out]
    assert len(out) > 100
    # The bottom's half stays on the bottom, with a little spread, and misses the far side.
    assert np.isclose(centres[:, 2], -20).mean() > 0.95
    assert (centres[:, 0] < 10).all()
    assert (centres[:, 2] < -5).all()


def test_scene_splits_objects_plates_and_copies():
    a = trimesh.creation.box((10, 10, 10))
    verts = "".join(f'<vertex x="{x}" y="{y}" z="{z}"/>' for x, y, z in a.vertices)
    tris = "".join(f'<triangle v1="{p}" v2="{q}" v3="{r}"/>' for p, q, r in a.faces)
    mesh = f"<mesh><vertices>{verts}</vertices><triangles>{tris}</triangles></mesh>"
    model = (
        '<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources>'
        f'<object id="1" type="model">{mesh}</object><object id="2" type="model" name="Plain">{mesh}</object>'
        '</resources><build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 5 6 7"/><item objectid="1"/><item objectid="2"/></build></model>'
    )
    settings_xml = (
        '<config><object id="1"><metadata key="name" value="Named"/></object>'
        '<plate><metadata key="plater_id" value="1"/><metadata key="plater_name" value="First"/>'
        '<model_instance><metadata key="object_id" value="1"/><metadata key="instance_id" value="0"/></model_instance></plate>'
        '<plate><metadata key="plater_id" value="2"/>'
        '<model_instance><metadata key="object_id" value="1"/><metadata key="instance_id" value="1"/></model_instance>'
        '<model_instance><metadata key="object_id" value="2"/><metadata key="instance_id" value="0"/></model_instance></plate></config>'
    )
    from app.threemf import read_scene

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "p.3mf"
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("3D/3dmodel.model", model)
            z.writestr("Metadata/model_settings.config", settings_xml)
        written = []
        scene = read_scene(path, lambda n, v, f, paint: written.append((n, len(f))))
    assert written == [(0, 12), (1, 12)]
    assert scene["plates"] == [{"index": 1, "name": "First"}, {"index": 2, "name": ""}]
    assert [o["name"] for o in scene["objects"]] == ["Named", "Plain"]
    assert [(i["object"], i["plate"]) for i in scene["items"]] == [(0, 1), (0, 2), (1, 2)]
    assert scene["items"][0]["matrix"][12:15] == [5, 6, 7]


def test_decode_paint():
    from app.threemf import decode_paint

    assert decode_paint("4") == 1
    assert decode_paint("8") == 2
    assert decode_paint("0") == 0
    # Split into two (last digit, read first, is 1): half blocker counts, half enforcer wins.
    assert decode_paint("081") == 2
    assert decode_paint("041") == 1
    # Split into four, one blocker: not enough. One enforcer out of four: enough.
    assert decode_paint("00083") == 0
    assert decode_paint("00043") == 1


def test_refine_carries_paint():
    box = trimesh.creation.box((40, 40, 40))
    paint = np.zeros(len(box.faces), dtype=np.uint8)
    paint[3] = 2
    v, f, p = prepare.refine_with_paint(box.vertices, box.faces, paint, 5.0)
    assert len(f) > 100 and len(p) == len(f)
    painted = trimesh.Trimesh(v, f, process=False).triangles_center[p == 2]
    original = box.triangles[3]
    assert (np.abs(painted - original.mean(axis=0)).max(axis=0) <= np.ptp(original, axis=0) + 1e-6).all()
    assert np.isclose(trimesh.Trimesh(v, f, process=False).area_faces[p == 2].sum(), box.area_faces[3])


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
