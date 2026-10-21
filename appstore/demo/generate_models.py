"""Procedural demo models for the App Review server. Writes one folder per model to argv[1]."""
import sys
from pathlib import Path

import numpy as np
import trimesh

OUT = Path(sys.argv[1])
TAU = 2 * np.pi


def loft(rings, cap_bottom=True, cap_top=True):
    """Skin a list of rings (each N x 3, same N, counter-clockwise) into a closed mesh."""
    rings = [np.asarray(r, float) for r in rings]
    n = len(rings[0])
    verts = np.vstack(rings)
    faces = []
    for k in range(len(rings) - 1):
        a, b = k * n, (k + 1) * n
        for i in range(n):
            j = (i + 1) % n
            faces += [[a + i, a + j, b + j], [a + i, b + j, b + i]]
    extra = []
    if cap_bottom:
        c = len(verts) + len(extra)
        extra.append(rings[0].mean(axis=0))
        faces += [[c, (i + 1) % n, i] for i in range(n)]
    if cap_top:
        c = len(verts) + len(extra)
        extra.append(rings[-1].mean(axis=0))
        base = (len(rings) - 1) * n
        faces += [[c, base + i, base + (i + 1) % n] for i in range(n)]
    if extra:
        verts = np.vstack([verts, extra])
    m = trimesh.Trimesh(verts, faces, process=True)
    trimesh.repair.fix_normals(m)
    return m


def tube(outer, inner, z0, z1, steps=1, twist=0.0):
    """Hollow prism between two radial profiles r(theta, t), t in [0, 1] along the height."""
    th = np.linspace(0, TAU, len(outer(0)), endpoint=False)
    def ring(r, t):
        a = th + twist * t
        return np.c_[r * np.cos(a), r * np.sin(a), np.full_like(th, z0 + (z1 - z0) * t)]
    ts = np.linspace(0, 1, steps + 1)
    o = [ring(outer(t), t) for t in ts]
    i = [ring(inner(t), t) for t in ts]
    n = len(th)
    verts = np.vstack(o + i)
    faces = []
    m = len(ts)
    def side(off, flip):
        for k in range(m - 1):
            a, b = off + k * n, off + (k + 1) * n
            for p in range(n):
                q = (p + 1) % n
                f = [[a + p, a + q, b + q], [a + p, b + q, b + p]]
                faces.extend([x[::-1] for x in f] if flip else f)
    side(0, False)
    side(m * n, True)
    ib = m * n
    for p in range(n):
        q = (p + 1) % n
        faces += [[p, ib + q, q], [p, ib + p, ib + q]]  # bottom annulus
        t0, t1 = (m - 1) * n, ib + (m - 1) * n
        faces += [[t0 + p, t0 + q, t1 + q], [t0 + p, t1 + q, t1 + p]]  # top annulus
    mesh = trimesh.Trimesh(verts, faces, process=True)
    trimesh.repair.fix_normals(mesh)
    return mesh


def prism(radius_fn, n, z0, z1, steps=1, twist=0.0):
    th = np.linspace(0, TAU, n, endpoint=False)
    rings = []
    for t in np.linspace(0, 1, steps + 1):
        r = radius_fn(th, t)
        a = th + twist * t
        rings.append(np.c_[r * np.cos(a), r * np.sin(a), np.full(n, z0 + (z1 - z0) * t)])
    return loft(rings)


def box(x, y, z, at=(0, 0, 0)):
    b = trimesh.creation.box((x, y, z))
    b.apply_translation(np.add(at, (0, 0, z / 2)))
    return b


def join(*parts):
    return trimesh.util.concatenate(parts)


def save(folder, name, mesh):
    d = OUT / folder
    d.mkdir(parents=True, exist_ok=True)
    mesh.export(d / name)


def gear_profile(teeth, r_root, r_tip, n=720):
    def r(th, t=0):
        phase = (th * teeth / TAU) % 1.0
        # trapezoid tooth: rise, top land, fall, bottom land
        y = np.clip(np.minimum((phase - 0.05) / 0.15, (0.75 - phase) / 0.15), 0, 1)
        return r_root + (r_tip - r_root) * y
    return r


def threads(r0, depth, pitch, height):
    def r(th, t):
        frac = (th / TAU + t * height / pitch) % 1.0
        return r0 - depth * np.abs(2 * frac - 1)
    return r


# Spur gear with a keyed bore, and a smaller pinion.
for folder, teeth, rt in [("Spur Gear Set", 32, 34.0), ("Spur Gear Set", 12, 14.0)]:
    g = gear_profile(teeth, rt - 3.2, rt)
    n = 1440
    th = np.linspace(0, TAU, n, endpoint=False)
    gear = tube(lambda t: g(th), lambda t: np.full(n, 4.0), 0, 8)
    hub = tube(lambda t: np.full(n, 9.0), lambda t: np.full(n, 4.0), 8, 14)
    save(folder, f"gear_{teeth}t.stl", join(gear, hub))

# Twisted vase (vase mode): 9-lobed profile with a slow twist and a bulging waist.
def vase_r(th, t):
    bulge = 32 + 14 * np.sin(np.pi * t * 0.9) - 6 * t
    return bulge * (1 + 0.08 * np.cos(9 * th))
save("Twisted Vase", "twisted_vase.stl", prism(vase_r, 540, 0, 150, steps=120, twist=np.pi * 0.8))

# M10 bolt and nut with real-looking threads.
n = 120
th = np.linspace(0, TAU, n, endpoint=False)
hexr = lambda t: 8.66 / np.cos(((th + np.pi / 6) % (np.pi / 3)) - np.pi / 6)
head = prism(lambda a, t: 8.66 / np.cos(((a + np.pi / 6) % (np.pi / 3)) - np.pi / 6), n, 0, 6.5)
shaft = prism(threads(5.0, 0.9, 1.5, 40), n, 6.5, 46.5, steps=240)
save("M10 Bolt and Nut", "m10_bolt.stl", join(head, shaft))
nut = tube(hexr, lambda t: 5.1 + 0.9 - 0.9 * np.abs(2 * ((th / TAU + t * 8 / 1.5) % 1) - 1), 0, 8, steps=48)
nut.apply_translation((30, 0, 0))
save("M10 Bolt and Nut", "m10_nut.stl", nut)

# Planter with drainage saucer (revolved profiles).
def revolve(profile, sections=256):
    return trimesh.creation.revolve(np.asarray(profile, float), sections=sections)
pot = revolve([[30, 0], [55, 0], [70, 110], [74, 110], [74, 116], [64, 116], [50, 6], [30, 6]])
saucer = revolve([[0, 0], [62, 0], [68, 14], [64, 14], [58, 3], [0, 3]])
saucer.apply_translation((170, 0, 0))
save("Planter and Saucer", "planter.stl", pot)
save("Planter and Saucer", "saucer.stl", saucer)

# Gridfinity-style 2x1 bin with a divider.
w, d, h, wall = 83.5, 41.5, 42, 1.6
bin_ = join(
    box(w, d, 5), box(w, wall, h, (0, d / 2 - wall / 2, 0)), box(w, wall, h, (0, -d / 2 + wall / 2, 0)),
    box(wall, d, h, (w / 2 - wall / 2, 0, 0)), box(wall, d, h, (-w / 2 + wall / 2, 0, 0)),
    box(wall, d, h * 0.8, (0, 0, 0)), box(w, 12, 2, (0, d / 2 - 6, h - 2)),
)
save("Gridfinity Bin 2x1", "bin_2x1.stl", bin_)

# Honeycomb wall panel built from hex cells.
cells = []
r_out, r_in = 20.0, 18.2
hx = lambda r: (lambda t: r / np.cos(((np.linspace(0, TAU, 6, endpoint=False) + 0) % (np.pi / 3)) - np.pi / 6) * 0 + r)
for row in range(3):
    for col in range(4):
        cx = col * r_out * 1.5
        cy = row * r_out * np.sqrt(3) + (col % 2) * r_out * np.sqrt(3) / 2
        c = tube(lambda t: np.full(6, r_out), lambda t: np.full(6, r_in), 0, 22)
        c.apply_translation((cx, cy, 0))
        cells.append(c)
save("Honeycomb Wall Shelf", "honeycomb_panel.stl", join(*cells))

# Adjustable phone stand: base, back rest and lip.
stand = join(box(80, 90, 5), box(80, 6, 100, (0, 10, 0)), box(80, 10, 18, (0, -30, 0)))
stand.vertices[stand.vertices[:, 2] > 60, 1] -= 25  # lean the back rest
save("Phone Stand", "phone_stand.stl", stand)

# Low-poly moon with craters.
moon = trimesh.creation.icosphere(subdivisions=3, radius=40)
rng = np.random.default_rng(7)
v = moon.vertices / 40
for c in rng.normal(size=(14, 3)):
    c /= np.linalg.norm(c)
    dist = np.linalg.norm(v - c, axis=1)
    moon.vertices -= (v * (np.clip(0.35 - dist, 0, None) * 18)[:, None])
moon.vertices += moon.vertices * rng.normal(0, 0.012, (len(v), 1))
save("Low Poly Moon Lamp", "moon.stl", moon)

# Calibration cube.
cube = join(box(20, 20, 20))
save("Calibration Cube", "xyz_cube_20mm.stl", cube)

# Spool holder: axle, flange and a bearing seat.
holder = join(
    tube(lambda t: np.full(256, 26.0), lambda t: np.full(256, 4.0), 0, 4),
    tube(lambda t: np.full(256, 11.0), lambda t: np.full(256, 4.0), 4, 70),
    tube(lambda t: np.full(256, 14.0), lambda t: np.full(256, 11.2), 60, 70),
)
save("Spool Holder Axle", "spool_axle.stl", holder)

# Cable clips in three sizes (open rings).
clips = []
for k, r in enumerate([4.0, 6.0, 8.0]):
    n = 200
    th = np.linspace(0.6, TAU - 0.6, n)
    ring = trimesh.creation.torus(major_radius=r + 1.2, minor_radius=1.2, major_sections=64, minor_sections=16)
    base = box(2 * r + 8, 6, 2.4, (k * 30, -r - 2.4, 0))
    ring.apply_translation((k * 30, 0, 1.2))
    clips += [ring, base]
save("Cable Clips", "cable_clips.stl", join(*clips))

# Desk organiser: three cups of different heights.
cups = []
for k, (r, h) in enumerate([(22, 95), (18, 75), (15, 55)]):
    c = revolve([[0, 0], [r, 0], [r, h], [r - 1.8, h], [r - 1.8, 2], [0, 2]])
    c.apply_translation((k * 46, 0, 0))
    cups.append(c)
save("Desk Organiser Cups", "organiser_cups.3mf", join(*cups))

print(sorted(p.name for p in OUT.iterdir()))
