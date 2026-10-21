import sys
import time
from pathlib import Path

import httpx

base = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8765"
t = Path(__file__).parent / "t"
c = httpx.Client(base_url=base + "/api/v1", timeout=60)

st = c.get("/auth/status").json()
if st["needs_setup"]:
    r = c.post("/auth/setup", json={"username": "jake", "password": "password123"})
else:
    r = c.post("/auth/login", json={"username": "jake", "password": "password123"})
print("auth", r.status_code)

bid = c.post("/uploads").json()["id"]
names = ["benchy_hull.stl", "benchy_mast.stl", "widget.obj", "ball.3mf", "tower.step", "tower.gcode", "763622-gridfinity-bin.zip"]
files = [("files", (n, open(t / n, "rb"))) for n in names]
files += [("files", ("a.stl", open(t / "benchy_hull.stl", "rb"))), ("files", ("b.obj", open(t / "widget.obj", "rb")))]
data = {"paths": [""] * len(names) + ["Shelf/Things/a.stl", "Shelf/Other/b.obj"]}
r = c.post(f"/uploads/{bid}/files", files=files, data=data)
print("stage", r.status_code)
d = r.json()
for f in d["files"]:
    print("  file", f["path"], f["hint"], f["kind"], "dup" if f["dup_model_id"] else "")
for g in d["groups"]:
    print("  group", g["name"], len(g["file_ids"]))

r = c.post(f"/uploads/{bid}/commit", json={"groups": d["groups"]})
print("commit", r.status_code, r.json())
ids = r.json()["model_ids"]

for _ in range(90):
    s = c.get("/jobs/summary").json()
    if not s["counts"].get("queued") and not s["counts"].get("running"):
        break
    time.sleep(1)
print("jobs", s["counts"], [e["error"] for e in s["recent_errors"]])

for mid in ids:
    m = c.get(f"/models/{mid}").json()
    print(f"model {m['name']!r} parts={m['part_count']} tris={m['tri_count']} size={m['size_x']},{m['size_y']},{m['size_z']} cover={m['cover_file_id']}")
    for f in m["files"]:
        print(f"   {f['rel_path']} {f['kind']} {f['status']} thumb={f['has_thumb']} prev={f['has_preview']} {f['meta']} {f['error'][:80]}")

print("list", c.get("/models").json()["total"])
print("search benchy", [m["name"] for m in c.get("/models", params={"q": "mast"}).json()["items"]])
print("fits mini", [m["name"] for m in c.get("/models", params={"printer_id": 2}).json()["items"]])
print("ext step", [m["name"] for m in c.get("/models", params={"ext": "step"}).json()["items"]])
r = c.post("/models/bulk", json={"ids": ids[:2], "add_tags": ["Test Tag"], "status": "to_print", "favourite": True})
print("bulk", r.json())
print("status to_print", [m["name"] for m in c.get("/models", params={"status": "to_print"}).json()["items"]])
print("tags", c.get("/tags").json())
cat = c.post("/categories", json={"name": "Tools"}).json()
sub = c.post("/categories", json={"name": "Clamps", "parent_id": cat["id"]}).json()
c.patch(f"/models/{ids[0]}", json={"category_id": sub["id"]})
print("cat Tools", [m["name"] for m in c.get("/models", params={"category_id": cat["id"]}).json()["items"]])
print("untriaged", c.get("/stats").json())
r = c.get(f"/models/{ids[0]}/download")
print("zip", r.status_code, len(r.content))
print("thumb", c.get(f"/files/{c.get(f'/models/{ids[0]}').json()['cover_file_id']}/thumb").status_code)
c.delete(f"/models/{ids[-1]}")
print("after delete", c.get("/models").json()["total"], "trash", c.get("/models", params={"trashed": True}).json()["total"])
c.post(f"/models/{ids[-1]}/restore")
print("restored", c.get("/models").json()["total"])
