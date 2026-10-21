from contextlib import contextmanager
from typing import Iterator

from sqlalchemy import create_engine, event, text
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from .config import settings


class Base(DeclarativeBase):
    pass


engine = None
SessionLocal: sessionmaker | None = None


def init_engine() -> None:
    global engine, SessionLocal
    settings.ensure_dirs()
    engine = create_engine(
        f"sqlite:///{settings.db_path}",
        connect_args={"check_same_thread": False, "timeout": 30},
    )

    @event.listens_for(engine, "connect")
    def _pragmas(dbapi_conn, _):
        cur = dbapi_conn.cursor()
        cur.execute("PRAGMA journal_mode=WAL")
        cur.execute("PRAGMA foreign_keys=ON")
        cur.execute("PRAGMA synchronous=NORMAL")
        cur.close()

    SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)


def create_schema() -> None:
    from . import models  # noqa: F401  register tables

    Base.metadata.create_all(engine)
    _ensure_autoincrement([Base.metadata.tables["models"], Base.metadata.tables["files"]])
    with engine.begin() as conn:
        conn.execute(
            text(
                "CREATE VIRTUAL TABLE IF NOT EXISTS model_fts USING fts5("
                "model_id UNINDEXED, name, description, tags, filenames, author, "
                "tokenize='unicode61 remove_diacritics 2')"
            )
        )


def _ensure_autoincrement(tables) -> None:
    """Rebuild tables created before they used AUTOINCREMENT, keeping rows and indexes.

    Without AUTOINCREMENT SQLite hands the id of the newest deleted row to the next insert.
    Runs on a raw connection because SQLite ignores PRAGMA foreign_keys inside a transaction,
    and dropping the old table with foreign keys on would cascade-delete child rows.
    """
    from sqlalchemy.schema import CreateIndex, CreateTable

    raw = engine.raw_connection()
    try:
        db = raw.driver_connection
        db.isolation_level = None  # explicit BEGIN/COMMIT below
        cur = db.cursor()
        cur.execute("PRAGMA foreign_keys=OFF")
        # Keep other tables' foreign keys naming the table, so they follow it to the rebuilt copy.
        cur.execute("PRAGMA legacy_alter_table=ON")
        # The API and worker both start here; the write lock makes the second one see the finished rebuild.
        cur.execute("BEGIN IMMEDIATE")
        try:
            todo = []
            for table in tables:
                row = cur.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (table.name,)).fetchone()
                if row and "AUTOINCREMENT" not in row[0].upper():
                    todo.append(table)
            for table in todo:
                tmp = f"{table.name}__old"
                cur.execute(f'ALTER TABLE "{table.name}" RENAME TO "{tmp}"')
                for index in table.indexes:
                    cur.execute(f'DROP INDEX IF EXISTS "{index.name}"')
                cur.execute(str(CreateTable(table).compile(dialect=engine.dialect)))
                cols = ", ".join(f'"{c.name}"' for c in table.columns)
                cur.execute(f'INSERT INTO "{table.name}" ({cols}) SELECT {cols} FROM "{tmp}"')
                cur.execute(f'DROP TABLE "{tmp}"')
                for index in table.indexes:
                    cur.execute(str(CreateIndex(index).compile(dialect=engine.dialect)))
            if cur.execute("PRAGMA foreign_key_check").fetchall():
                raise RuntimeError("foreign key check failed after rebuilding tables")
            cur.execute("COMMIT")
        except Exception:
            cur.execute("ROLLBACK")
            raise
        finally:
            cur.execute("PRAGMA legacy_alter_table=OFF")
            cur.execute("PRAGMA foreign_keys=ON")
    finally:
        raw.close()


def get_db() -> Iterator[Session]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


@contextmanager
def session_scope() -> Iterator[Session]:
    db = SessionLocal()
    try:
        yield db
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
