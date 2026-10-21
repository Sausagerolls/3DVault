import time

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from .auth import (
    COOKIE_NAME,
    current_user,
    hash_password,
    issue_token,
    require_admin,
    revoke_token,
    verify_password,
)
from .config import settings
from .db import get_db
from .models import Token, User
from .schemas import UserOut

router = APIRouter(prefix="/api/v1", tags=["auth"])

# username -> recent failed login timestamps; slows password guessing.
_failures: dict[str, list[float]] = {}
MAX_FAILURES, FAILURE_WINDOW = 5, 300


class SetupIn(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    display_name: str = ""
    password: str = Field(min_length=8)


class LoginIn(BaseModel):
    username: str
    password: str
    # Set by native apps: returns a long-lived device token instead of a cookie.
    device_name: str | None = None


class UserIn(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    display_name: str = ""
    password: str = Field(min_length=8)
    role: str = "member"


class UserPatch(BaseModel):
    display_name: str | None = None
    password: str | None = Field(default=None, min_length=8)
    role: str | None = None


class PasswordIn(BaseModel):
    current_password: str
    new_password: str = Field(min_length=8)


def _set_cookie(response: Response, raw: str) -> None:
    response.set_cookie(
        COOKIE_NAME,
        raw,
        max_age=settings.session_days * 86400,
        httponly=True,
        samesite="lax",
        secure=settings.cookie_secure,
    )


@router.get("/auth/status")
def status(db: Session = Depends(get_db)):
    return {"needs_setup": db.query(User).count() == 0, "version": "1.0.0"}


@router.post("/auth/setup", response_model=UserOut)
def setup(body: SetupIn, response: Response, db: Session = Depends(get_db)):
    if db.query(User).count() > 0:
        raise HTTPException(409, "Already set up")
    user = User(
        username=body.username.strip().lower(),
        display_name=body.display_name or body.username,
        password_hash=hash_password(body.password),
        role="admin",
    )
    db.add(user)
    db.commit()
    _set_cookie(response, issue_token(db, user, "session", "web"))
    return UserOut.model_validate(user, from_attributes=True)


@router.post("/auth/login")
def login(body: LoginIn, request: Request, response: Response, db: Session = Depends(get_db)):
    name = body.username.strip().lower()
    now = time.time()
    recent = [t for t in _failures.get(name, []) if now - t < FAILURE_WINDOW]
    if len(recent) >= MAX_FAILURES:
        raise HTTPException(429, "Too many failed attempts. Try again in a few minutes.")
    user = db.query(User).filter(User.username == name).first()
    if not user or not verify_password(user.password_hash, body.password):
        _failures[name] = recent + [now]
        raise HTTPException(401, "Wrong username or password")
    _failures.pop(name, None)
    out = {"user": UserOut.model_validate(user, from_attributes=True).model_dump()}
    if body.device_name:
        out["token"] = issue_token(db, user, "device", body.device_name[:128])
    else:
        ua = request.headers.get("user-agent", "")[:120]
        _set_cookie(response, issue_token(db, user, "session", ua))
    return out


@router.post("/auth/logout", status_code=204)
def logout(request: Request, response: Response, db: Session = Depends(get_db)):
    raw = request.cookies.get(COOKIE_NAME)
    header = request.headers.get("authorization", "")
    if header.lower().startswith("bearer "):
        raw = header[7:].strip()
    if raw:
        revoke_token(db, raw)
    response.delete_cookie(COOKIE_NAME)


@router.get("/auth/me", response_model=UserOut)
def me(user: User = Depends(current_user)):
    return UserOut.model_validate(user, from_attributes=True)


@router.post("/auth/password", status_code=204)
def change_password(body: PasswordIn, db: Session = Depends(get_db), user: User = Depends(current_user)):
    if not verify_password(user.password_hash, body.current_password):
        raise HTTPException(400, "Current password is wrong")
    user.password_hash = hash_password(body.new_password)
    db.commit()


# ---------------------------------------------------------------- tokens


@router.get("/tokens")
def list_tokens(request: Request, db: Session = Depends(get_db), user: User = Depends(current_user)):
    rows = db.query(Token).filter(Token.user_id == user.id).order_by(Token.created_at.desc()).all()
    return [
        {
            "id": t.id,
            "kind": t.kind,
            "name": t.name,
            "created_at": t.created_at,
            "last_used_at": t.last_used_at,
            "current": t.id == getattr(request.state, "token_id", None),
        }
        for t in rows
    ]


@router.post("/tokens")
def create_token(name: str, db: Session = Depends(get_db), user: User = Depends(current_user)):
    return {"token": issue_token(db, user, "device", name[:128])}


@router.delete("/tokens/{token_id}", status_code=204)
def delete_token(token_id: int, db: Session = Depends(get_db), user: User = Depends(current_user)):
    db.query(Token).filter(Token.id == token_id, Token.user_id == user.id).delete()
    db.commit()


# ---------------------------------------------------------------- users (admin)


@router.get("/users", response_model=list[UserOut])
def list_users(db: Session = Depends(get_db), user: User = Depends(current_user)):
    return [UserOut.model_validate(u, from_attributes=True) for u in db.query(User).order_by(User.username)]


@router.post("/users", response_model=UserOut)
def create_user(body: UserIn, db: Session = Depends(get_db), admin: User = Depends(require_admin)):
    name = body.username.strip().lower()
    if db.query(User).filter(User.username == name).first():
        raise HTTPException(409, "Username taken")
    if body.role not in ("admin", "member"):
        raise HTTPException(400, "role must be admin or member")
    u = User(username=name, display_name=body.display_name or body.username, password_hash=hash_password(body.password), role=body.role)
    db.add(u)
    db.commit()
    return UserOut.model_validate(u, from_attributes=True)


@router.patch("/users/{user_id}", response_model=UserOut)
def patch_user(user_id: int, body: UserPatch, db: Session = Depends(get_db), admin: User = Depends(require_admin)):
    u = db.get(User, user_id)
    if u is None:
        raise HTTPException(404)
    if body.display_name is not None:
        u.display_name = body.display_name
    if body.password:
        u.password_hash = hash_password(body.password)
        db.query(Token).filter(Token.user_id == u.id).delete()
    if body.role is not None:
        if body.role not in ("admin", "member"):
            raise HTTPException(400, "role must be admin or member")
        if u.role == "admin" and body.role != "admin" and db.query(User).filter(User.role == "admin").count() == 1:
            raise HTTPException(400, "Cannot demote the last admin")
        u.role = body.role
    db.commit()
    return UserOut.model_validate(u, from_attributes=True)


@router.delete("/users/{user_id}", status_code=204)
def delete_user(user_id: int, db: Session = Depends(get_db), admin: User = Depends(require_admin)):
    if user_id == admin.id:
        raise HTTPException(400, "Cannot delete yourself")
    u = db.get(User, user_id)
    if u:
        db.delete(u)
        db.commit()
