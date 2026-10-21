from .db import session_scope
from .models import Printer

DEFAULT_PRINTERS = [
    ("Bambu A1 / P1 / X1", 256, 256, 256),
    ("Bambu A1 mini", 180, 180, 180),
    ("Prusa MK4 / Core One", 250, 210, 220),
    ("Prusa MINI", 180, 180, 180),
]


def seed_defaults() -> None:
    with session_scope() as db:
        if db.query(Printer).filter(Printer.builtin.is_(True)).count() == 0:
            for name, x, y, z in DEFAULT_PRINTERS:
                if not db.query(Printer).filter(Printer.name == name).first():
                    db.add(Printer(name=name, x=x, y=y, z=z, builtin=True))
