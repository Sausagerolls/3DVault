import hashlib
import secrets
from datetime import timedelta

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from fastapi import Depends, HTTPException, Request
from sqlalchemy.orm import Session

from .config import settings
from .db import get_db
from .models import Token, User, utcnow

COOKIE_NAME = "vault_session"
_hasher = PasswordHasher()


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    try:
        return _hasher.verify(password_hash, password)
    except VerifyMismatchError:
        return False
    except Exception:
        return False


def _digest(raw: str) -> str:
    return hashlib.sha256(raw.encode()).hexdigest()


def issue_token(db: Session, user: User, kind: str, name: str = "") -> str:
    raw = secrets.token_urlsafe(32)
    expires = utcnow() + timedelta(days=settings.session_days) if kind == "session" else None
    db.add(Token(user_id=user.id, token_hash=_digest(raw), kind=kind, name=name, expires_at=expires))
    db.commit()
    return raw


def revoke_token(db: Session, raw: str) -> None:
    db.query(Token).filter(Token.token_hash == _digest(raw)).delete()
    db.commit()


def _raw_token(request: Request) -> str | None:
    header = request.headers.get("authorization", "")
    if header.lower().startswith("bearer "):
        return header[7:].strip()
    return request.cookies.get(COOKIE_NAME)


def current_user(request: Request, db: Session = Depends(get_db)) -> User:
    raw = _raw_token(request)
    if not raw:
        raise HTTPException(401, "Not authenticated")
    token = db.query(Token).filter(Token.token_hash == _digest(raw)).first()
    now = utcnow()
    if not token or (token.expires_at and token.expires_at < now):
        raise HTTPException(401, "Invalid or expired token")
    if not token.last_used_at or (now - token.last_used_at).total_seconds() > 300:
        token.last_used_at = now
        db.commit()
    request.state.token_id = token.id
    return token.user


def require_admin(user: User = Depends(current_user)) -> User:
    if user.role != "admin":
        raise HTTPException(403, "Admin only")
    return user
