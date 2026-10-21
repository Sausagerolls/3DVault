from datetime import datetime

from pydantic import BaseModel, Field


class UserOut(BaseModel):
    id: int
    username: str
    display_name: str
    role: str


class TagOut(BaseModel):
    id: int
    name: str
    count: int | None = None


class CategoryOut(BaseModel):
    id: int
    name: str
    parent_id: int | None
    count: int = 0


class PrinterOut(BaseModel):
    id: int
    name: str
    x: float
    y: float
    z: float
    builtin: bool


class FileOut(BaseModel):
    id: int
    rel_path: str
    kind: str
    ext: str
    size: int
    sha256: str
    size_x: float | None
    size_y: float | None
    size_z: float | None
    tri_count: int | None
    meta: dict
    has_thumb: bool
    has_preview: bool
    status: str
    error: str
    created_at: datetime


class FlagOut(BaseModel):
    id: int
    kind: str
    note: str
    user_id: int | None
    resolved: bool
    created_at: datetime


class MyState(BaseModel):
    favourite: bool = False
    rating: int | None = None
    status: str | None = None


class ModelSummary(BaseModel):
    id: int
    slug: str
    name: str
    category_id: int | None
    tags: list[str]
    cover_file_id: int | None
    cover_has_preview: bool = False
    preview_file_id: int | None = None
    untriaged: bool
    size_x: float | None
    size_y: float | None
    size_z: float | None
    part_count: int
    tri_count: int
    flag_count: int = 0
    created_at: datetime
    updated_at: datetime
    deleted_at: datetime | None
    me: MyState
    processing: bool = False


class ModelDetail(ModelSummary):
    description: str
    source_url: str
    author: str
    license: str
    print_notes: str
    printer_ids: list[int]
    uploader: UserOut | None
    category_path: list[str]
    files: list[FileOut]
    flags: list[FlagOut]
    collection_ids: list[int]


class ModelPage(BaseModel):
    items: list[ModelSummary]
    total: int
    page: int
    page_size: int


class ModelPatch(BaseModel):
    name: str | None = None
    description: str | None = None
    category_id: int | None = Field(default=None)
    clear_category: bool = False
    tags: list[str] | None = None
    source_url: str | None = None
    author: str | None = None
    license: str | None = None
    print_notes: str | None = None
    printer_ids: list[int] | None = None
    cover_file_id: int | None = None
    untriaged: bool | None = None


class MyStatePatch(BaseModel):
    favourite: bool | None = None
    rating: int | None = Field(default=None, ge=0, le=5)  # 0 clears
    status: str | None = None  # "" clears


class FlagIn(BaseModel):
    kind: str
    note: str = ""


class BulkAction(BaseModel):
    ids: list[int]
    category_id: int | None = None
    clear_category: bool = False
    add_tags: list[str] = []
    remove_tags: list[str] = []
    status: str | None = None
    favourite: bool | None = None
    add_flag: FlagIn | None = None
    add_to_collection: int | None = None
    remove_from_collection: int | None = None
    untriaged: bool | None = None
    delete: bool = False
    restore: bool = False
    printer_ids_add: list[int] = []


class CommitGroup(BaseModel):
    name: str
    file_ids: list[str]
    category_id: int | None = None
    tags: list[str] = []
    source_url: str = ""
    skip_duplicates: bool = False


class CommitIn(BaseModel):
    groups: list[CommitGroup]
