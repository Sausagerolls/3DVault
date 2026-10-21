"""Files the demo models into categories with tags and notes. Run inside the container:
docker exec -i 3DVault-Demo python - < curate.py

Run it after the inbox import has finished (the import needs an admin account to exist)."""
from app import db as database
from app.db import session_scope
from app.library import update_fts
from app.models import Model
from app.services import get_or_create_category_path, get_or_create_tags

DEMO = {
    "Spur Gear Set": (["Mechanical", "Gears"], ["gear", "functional", "pla"],
        "A 32-tooth gear and 12-tooth pinion with 8 mm bores.", "0.2 mm layers, 4 walls, 40% infill."),
    "M10 Bolt and Nut": (["Mechanical", "Fasteners"], ["functional", "threads", "petg"],
        "Printable M10 bolt and matching nut.", "Print the bolt standing up. 0.12 mm layers for clean threads."),
    "Spool Holder Axle": (["Mechanical"], ["functional", "printer upgrade"],
        "Spool axle with a 608 bearing seat.", "No supports. 3 walls."),
    "Twisted Vase": (["Home", "Decor"], ["vase mode", "decor", "silk pla"],
        "Nine-lobed vase with a gentle twist.", "Vase mode (spiralize outer contour), 0.6 mm nozzle recommended."),
    "Planter and Saucer": (["Home", "Garden"], ["planter", "petg", "decor"],
        "Tapered planter with a matching drip saucer.", "PETG for outdoor use. Drill a drainage hole after printing."),
    "Low Poly Moon Lamp": (["Home", "Decor"], ["lamp", "decor", "gift"],
        "Cratered low-poly moon. Hollow it in your slicer for an LED.", "0 % infill, 2 walls in white PLA for a lamp."),
    "Gridfinity Bin 2x1": (["Organisation", "Gridfinity"], ["gridfinity", "storage", "workshop"],
        "2x1 Gridfinity-style bin with a divider and label shelf.", "No supports needed."),
    "Honeycomb Wall Shelf": (["Organisation"], ["wall mount", "decor", "storage"],
        "Twelve-cell honeycomb wall shelf.", "Print flat. 15% gyroid infill."),
    "Desk Organiser Cups": (["Organisation", "Desk"], ["desk", "storage", "gift"],
        "Three nesting cups for pens and tools.", "3MF with all three parts on one plate."),
    "Phone Stand": (["Organisation", "Desk"], ["desk", "phone", "functional"],
        "Simple angled stand for phones and small tablets.", "Print on its side for strength."),
    "Cable Clips": (["Organisation", "Desk"], ["cable management", "desk", "quick print"],
        "Adhesive-backed cable clips for 8, 12 and 16 mm cables.", "Prints in under 10 minutes."),
    "Calibration Cube": (["Calibration"], ["calibration", "quick print"],
        "20 mm cube for checking dimensional accuracy.", "Measure X, Y and Z with calipers. All should read 20.00 mm."),
}

database.init_engine()
with session_scope() as db:
    for m in db.query(Model).filter(Model.deleted_at.is_(None)):
        spec = DEMO.get(m.name)
        if not spec:
            print("skipped", m.name)
            continue
        path, tags, desc, notes = spec
        m.category = get_or_create_category_path(db, path)
        m.tags = get_or_create_tags(db, tags)
        m.description = desc
        m.print_notes = notes
        m.author = "3DVault demo"
        m.license = "CC0-1.0"
        m.untriaged = False
        db.flush()
        update_fts(db, m)
        print("filed", m.name)
