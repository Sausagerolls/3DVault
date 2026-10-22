"""Encrypts printer access codes and API keys at rest with a key kept in the data folder."""

from cryptography.fernet import Fernet, InvalidToken

from .config import settings

_fernet: Fernet | None = None


def _box() -> Fernet:
    global _fernet
    if _fernet is None:
        path = settings.data_dir / "secret.key"
        if not path.exists():
            path.write_bytes(Fernet.generate_key())
            path.chmod(0o600)
        _fernet = Fernet(path.read_bytes().strip())
    return _fernet


def seal(plain: str) -> str:
    return _box().encrypt(plain.encode()).decode() if plain else ""


def unseal(sealed: str) -> str:
    if not sealed:
        return ""
    try:
        return _box().decrypt(sealed.encode()).decode()
    except InvalidToken:
        return ""
