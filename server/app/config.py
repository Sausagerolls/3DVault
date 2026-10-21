import os
from pathlib import Path


class Settings:
    def __init__(self) -> None:
        self.library_dir = Path(os.environ.get("VAULT_LIBRARY", "/library"))
        self.data_dir = Path(os.environ.get("VAULT_DATA", "/data"))
        self.inbox_dir = Path(os.environ.get("VAULT_INBOX", "/inbox"))
        self.web_dir = Path(os.environ.get("VAULT_WEB", Path(__file__).parent.parent / "web"))
        self.trash_days = int(os.environ.get("VAULT_TRASH_DAYS", "30"))
        self.inbox_poll_seconds = int(os.environ.get("VAULT_INBOX_POLL", "30"))
        self.session_days = int(os.environ.get("VAULT_SESSION_DAYS", "30"))
        self.cookie_secure = os.environ.get("VAULT_COOKIE_SECURE", "false").lower() == "true"

    @property
    def db_path(self) -> Path:
        return self.data_dir / "vault.db"

    @property
    def thumbs_dir(self) -> Path:
        return self.data_dir / "thumbs"

    @property
    def previews_dir(self) -> Path:
        return self.data_dir / "previews"

    @property
    def staging_dir(self) -> Path:
        return self.data_dir / "staging"

    @property
    def cache_dir(self) -> Path:
        return self.data_dir / "cache"

    @property
    def trash_dir(self) -> Path:
        return self.library_dir / ".trash"

    def ensure_dirs(self) -> None:
        for d in (
            self.library_dir,
            self.data_dir,
            self.thumbs_dir,
            self.previews_dir,
            self.staging_dir,
            self.cache_dir,
            self.trash_dir,
        ):
            d.mkdir(parents=True, exist_ok=True)


settings = Settings()
