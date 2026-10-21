from datetime import datetime, timezone

from sqlalchemy import (
    JSON,
    Boolean,
    Column,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Table,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .db import Base


def utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


model_tags = Table(
    "model_tags",
    Base.metadata,
    Column("model_id", ForeignKey("models.id", ondelete="CASCADE"), primary_key=True),
    Column("tag_id", ForeignKey("tags.id", ondelete="CASCADE"), primary_key=True),
)

model_printers = Table(
    "model_printers",
    Base.metadata,
    Column("model_id", ForeignKey("models.id", ondelete="CASCADE"), primary_key=True),
    Column("printer_id", ForeignKey("printers.id", ondelete="CASCADE"), primary_key=True),
)

collection_models = Table(
    "collection_models",
    Base.metadata,
    Column("collection_id", ForeignKey("collections.id", ondelete="CASCADE"), primary_key=True),
    Column("model_id", ForeignKey("models.id", ondelete="CASCADE"), primary_key=True),
)


class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    username: Mapped[str] = mapped_column(String(64), unique=True)
    display_name: Mapped[str] = mapped_column(String(128))
    password_hash: Mapped[str] = mapped_column(String(256))
    role: Mapped[str] = mapped_column(String(16), default="member")  # admin | member
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class Token(Base):
    __tablename__ = "tokens"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    kind: Mapped[str] = mapped_column(String(16))  # session | device
    name: Mapped[str] = mapped_column(String(128), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    user: Mapped[User] = relationship()


class Category(Base):
    __tablename__ = "categories"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(128))
    parent_id: Mapped[int | None] = mapped_column(
        ForeignKey("categories.id", ondelete="CASCADE"), nullable=True
    )
    sort: Mapped[int] = mapped_column(Integer, default=0)
    parent: Mapped["Category | None"] = relationship(remote_side=[id])
    __table_args__ = (UniqueConstraint("parent_id", "name"),)


class Tag(Base):
    __tablename__ = "tags"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(64), unique=True)


class Printer(Base):
    __tablename__ = "printers"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(128), unique=True)
    x: Mapped[float] = mapped_column(Float)
    y: Mapped[float] = mapped_column(Float)
    z: Mapped[float] = mapped_column(Float)
    builtin: Mapped[bool] = mapped_column(Boolean, default=False)


class Model(Base):
    __tablename__ = "models"
    # Never reuse ids: clients key offline copies by model id.
    __table_args__ = {"sqlite_autoincrement": True}
    id: Mapped[int] = mapped_column(primary_key=True)
    slug: Mapped[str] = mapped_column(String(160), unique=True)
    name: Mapped[str] = mapped_column(String(256))
    description: Mapped[str] = mapped_column(Text, default="")
    category_id: Mapped[int | None] = mapped_column(
        ForeignKey("categories.id", ondelete="SET NULL"), nullable=True, index=True
    )
    source_url: Mapped[str] = mapped_column(String(1024), default="")
    author: Mapped[str] = mapped_column(String(256), default="")
    license: Mapped[str] = mapped_column(String(128), default="")
    print_notes: Mapped[str] = mapped_column(Text, default="")
    cover_file_id: Mapped[int | None] = mapped_column(Integer, nullable=True)
    untriaged: Mapped[bool] = mapped_column(Boolean, default=True, index=True)
    uploader_id: Mapped[int | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow, index=True)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow, onupdate=utcnow)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True, index=True)
    # Aggregates over mesh files, refreshed by the worker.
    size_x: Mapped[float | None] = mapped_column(Float, nullable=True)
    size_y: Mapped[float | None] = mapped_column(Float, nullable=True)
    size_z: Mapped[float | None] = mapped_column(Float, nullable=True)
    tri_count: Mapped[int] = mapped_column(Integer, default=0)
    part_count: Mapped[int] = mapped_column(Integer, default=0)
    # Per-axis max of each part's sorted dimensions (largest first). A model fits a
    # bed when fit_a/b/c <= the bed's sorted dimensions, allowing parts to be rotated.
    fit_a: Mapped[float | None] = mapped_column(Float, nullable=True)
    fit_b: Mapped[float | None] = mapped_column(Float, nullable=True)
    fit_c: Mapped[float | None] = mapped_column(Float, nullable=True)

    category: Mapped[Category | None] = relationship()
    uploader: Mapped[User | None] = relationship()
    tags: Mapped[list[Tag]] = relationship(secondary=model_tags, order_by=Tag.name)
    printers: Mapped[list[Printer]] = relationship(secondary=model_printers)
    files: Mapped[list["File"]] = relationship(
        back_populates="model", cascade="all, delete-orphan", order_by="File.rel_path"
    )
    flags: Mapped[list["Flag"]] = relationship(cascade="all, delete-orphan")


class File(Base):
    __tablename__ = "files"
    id: Mapped[int] = mapped_column(primary_key=True)
    model_id: Mapped[int] = mapped_column(ForeignKey("models.id", ondelete="CASCADE"), index=True)
    rel_path: Mapped[str] = mapped_column(String(1024))
    # mesh | cad | gcode | project | image | photo | doc | other
    kind: Mapped[str] = mapped_column(String(16))
    ext: Mapped[str] = mapped_column(String(16))
    size: Mapped[int] = mapped_column(Integer, default=0)
    sha256: Mapped[str] = mapped_column(String(64), index=True)
    size_x: Mapped[float | None] = mapped_column(Float, nullable=True)
    size_y: Mapped[float | None] = mapped_column(Float, nullable=True)
    size_z: Mapped[float | None] = mapped_column(Float, nullable=True)
    tri_count: Mapped[int | None] = mapped_column(Integer, nullable=True)
    meta: Mapped[dict] = mapped_column(JSON, default=dict)
    has_thumb: Mapped[bool] = mapped_column(Boolean, default=False)
    has_preview: Mapped[bool] = mapped_column(Boolean, default=False)
    status: Mapped[str] = mapped_column(String(16), default="pending")  # pending|ready|error
    error: Mapped[str] = mapped_column(Text, default="")
    uploaded_by: Mapped[int | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    model: Mapped[Model] = relationship(back_populates="files")
    # sqlite_autoincrement: never reuse ids, because clients cache thumbnails and previews by file id.
    __table_args__ = (UniqueConstraint("model_id", "rel_path"), {"sqlite_autoincrement": True})


class UserModel(Base):
    """Per-user state for a model: favourite, rating, print status."""

    __tablename__ = "user_models"
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    model_id: Mapped[int] = mapped_column(
        ForeignKey("models.id", ondelete="CASCADE"), primary_key=True, index=True
    )
    favourite: Mapped[bool] = mapped_column(Boolean, default=False)
    rating: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # to_print | printed | failed | needs_remix
    status: Mapped[str | None] = mapped_column(String(16), nullable=True)


class Flag(Base):
    """Shared problem flag on a model."""

    __tablename__ = "flags"
    id: Mapped[int] = mapped_column(primary_key=True)
    model_id: Mapped[int] = mapped_column(ForeignKey("models.id", ondelete="CASCADE"), index=True)
    kind: Mapped[str] = mapped_column(String(32))  # broken_mesh | missing_parts | bad_scale | other
    note: Mapped[str] = mapped_column(Text, default="")
    user_id: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    resolved: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class Collection(Base):
    __tablename__ = "collections"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(128))
    owner_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(String(16), default="manual")  # manual | smart
    query: Mapped[dict] = mapped_column(JSON, default=dict)
    shared: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    models: Mapped[list[Model]] = relationship(secondary=collection_models)


class Rule(Base):
    """Auto-tag rule applied when models are imported."""

    __tablename__ = "rules"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(128))
    field: Mapped[str] = mapped_column(String(16))  # filename | name | source_url | any
    pattern: Mapped[str] = mapped_column(String(256))
    add_tags: Mapped[list] = mapped_column(JSON, default=list)
    category_id: Mapped[int | None] = mapped_column(
        ForeignKey("categories.id", ondelete="SET NULL"), nullable=True
    )
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)


class Setting(Base):
    __tablename__ = "settings"
    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[str] = mapped_column(Text, default="")


class Job(Base):
    __tablename__ = "jobs"
    id: Mapped[int] = mapped_column(primary_key=True)
    kind: Mapped[str] = mapped_column(String(32), index=True)
    payload: Mapped[dict] = mapped_column(JSON, default=dict)
    status: Mapped[str] = mapped_column(String(16), default="queued", index=True)  # queued|running|done|error
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    error: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)


class UploadBatch(Base):
    """Staged upload waiting for review before it becomes models."""

    __tablename__ = "upload_batches"
    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    source: Mapped[str] = mapped_column(String(16), default="web")  # web | inbox | app
    state: Mapped[str] = mapped_column(String(16), default="open")  # open | committed
    # [{"id": "f1", "path": "benchy/hull.stl", "size": 123, "sha256": "...", "dup_model_id": 3}]
    files: Mapped[list] = mapped_column(JSON, default=list)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
