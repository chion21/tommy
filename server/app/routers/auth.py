"""Accounts, login, devices and license keys."""
import secrets
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..config import DEVICE_TYPES, settings
from ..db import get_db
from ..deps import Ctx, client_ip, current, err, plan_active
from ..models import AssistantSettings, Device, License, User
from ..security import hash_key, hash_password, make_token, normalize_key, read_token, verify_password
from ..services import audit, quota

router = APIRouter(tags=["account"])
OFFLINE_GRACE = timedelta(days=3)


class RegisterIn(BaseModel):
    login: str = Field(min_length=5, max_length=120)  # phone number or email
    password: str = Field(min_length=6, max_length=128)
    display_name: str = Field(default="", max_length=60)


class LoginIn(BaseModel):
    login: str
    password: str
    device_uid: str = Field(min_length=8, max_length=128)
    device_type: str
    label: str = Field(default="", max_length=80)
    replace_device: bool = False  # user confirmed "remove my old phone/PC"


def _norm_login(s: str) -> str:
    return s.strip().lower().replace(" ", "")


@router.post("/auth/register")
def register(body: RegisterIn, request: Request, db: Session = Depends(get_db)):
    login = _norm_login(body.login)
    if db.scalar(select(User).where(User.login == login)):
        raise err(409, "LOGIN_TAKEN", "This phone/email is already registered")
    user = User(
        login=login, password_hash=hash_password(body.password), display_name=body.display_name.strip(),
        plan="trial", plan_expires_at=datetime.now(timezone.utc) + timedelta(days=settings.trial_days),
    )
    db.add(user)
    db.flush()
    db.add(AssistantSettings(user_id=user.id))
    audit(db, user.id, "register", ip=client_ip(request))
    db.commit()
    return {"user_id": user.id, "plan": user.plan, "plan_expires_at": user.plan_expires_at}


def _swaps_last_30d(db: Session, user_id: str) -> int:
    since = datetime.now(timezone.utc) - timedelta(days=30)
    return db.scalar(select(func.count()).select_from(Device).where(
        Device.user_id == user_id, Device.deactivated_at.is_not(None), Device.deactivated_at >= since)) or 0


@router.post("/auth/login")
def login(body: LoginIn, request: Request, db: Session = Depends(get_db)):
    ip = client_ip(request)
    if body.device_type not in DEVICE_TYPES:
        raise err(422, "BAD_DEVICE_TYPE", "device_type must be phone or pc")
    user = db.scalar(select(User).where(User.login == _norm_login(body.login)))
    if not user or not verify_password(body.password, user.password_hash):
        raise err(401, "BAD_LOGIN", "Wrong phone/email or password")
    if user.banned:
        raise err(403, "BANNED", "Account blocked")

    dev = db.scalar(select(Device).where(Device.user_id == user.id, Device.device_uid == body.device_uid))
    if dev and dev.device_type != body.device_type:
        raise err(422, "BAD_DEVICE_TYPE", "Device type mismatch")

    if not (dev and dev.active):
        # Is the phone/PC slot already taken by another device?
        other = db.scalar(select(Device).where(
            Device.user_id == user.id, Device.device_type == body.device_type, Device.active.is_(True)))
        if other:
            if not body.replace_device:
                raise err(409, "DEVICE_LIMIT",
                          f"Another {body.device_type} is already active ({other.label or 'unnamed'}). Replace it?")
            if _swaps_last_30d(db, user.id) >= settings.device_swaps_per_30d:
                audit(db, user.id, "swap_limit_hit", body.device_type, ip)
                db.commit()
                raise err(429, "SWAP_LIMIT", "Device can be changed at most 2 times in 30 days")
            other.active = False
            other.deactivated_at = datetime.now(timezone.utc)
            audit(db, user.id, "device_replaced", f"{other.label} -> {body.label}", ip)
        if dev:
            dev.active, dev.deactivated_at = True, None
        else:
            dev = Device(user_id=user.id, device_uid=body.device_uid, device_type=body.device_type, label=body.label)
            db.add(dev)
            db.flush()

    dev.session_id = secrets.token_hex(16)  # kills any older session on this device
    dev.label = body.label or dev.label
    dev.last_ip = ip
    audit(db, user.id, "login", body.device_type, ip)
    db.commit()
    token, exp = make_token(user.id, dev.id, dev.session_id)
    return {"token": token, "expires_at": exp, "user_id": user.id, "plan": user.plan,
            "plan_active": plan_active(user)}


class RefreshIn(BaseModel):
    token: str


@router.post("/auth/refresh")
def refresh(body: RefreshIn, db: Session = Depends(get_db)):
    """Accepts a token up to 3 days past expiry (offline grace), as long as the device is still valid."""
    try:
        claims = jwt.decode(body.token, settings.jwt_secret, algorithms=["HS256"], options={"verify_exp": False})
    except jwt.PyJWTError:
        raise err(401, "BAD_TOKEN", "Invalid session")
    if datetime.fromtimestamp(claims["exp"], timezone.utc) + OFFLINE_GRACE < datetime.now(timezone.utc):
        raise err(401, "TOKEN_TOO_OLD", "Please log in again")
    user, dev = db.get(User, claims["sub"]), db.get(Device, claims["dev"])
    if not user or not dev or user.banned or not dev.active or dev.session_id != claims["sid"]:
        raise err(401, "SESSION_REPLACED", "Please log in again")
    token, exp = make_token(user.id, dev.id, dev.session_id)
    return {"token": token, "expires_at": exp, "plan": user.plan, "plan_active": plan_active(user)}


@router.post("/auth/logout")
def logout(ctx: Ctx = Depends(current)):
    ctx.device.session_id = ""
    ctx.db.commit()
    return {"ok": True}


# ---------- devices ----------

@router.get("/devices")
def list_devices(ctx: Ctx = Depends(current)):
    rows = ctx.db.scalars(select(Device).where(Device.user_id == ctx.user.id, Device.active.is_(True))).all()
    return [{"id": d.id, "type": d.device_type, "label": d.label, "this_device": d.id == ctx.device.id,
             "last_seen_at": d.last_seen_at} for d in rows]


# ---------- license ----------

class RedeemIn(BaseModel):
    key: str


@router.post("/license/redeem")
def redeem(body: RedeemIn, request: Request, ctx: Ctx = Depends(current)):
    db = ctx.db
    lic = db.scalar(select(License).where(License.key_hash == hash_key(body.key)))
    if not lic or lic.revoked:
        audit(db, ctx.user.id, "bad_key", normalize_key(body.key)[-4:], client_ip(request))
        db.commit()
        raise err(404, "BAD_KEY", "License key not valid")
    if lic.redeemed_by:
        raise err(409, "KEY_USED", "This key was already used")
    now = datetime.now(timezone.utc)
    start = ctx.user.plan_expires_at
    start = start.replace(tzinfo=timezone.utc) if start.tzinfo is None else start
    # Same plan → extend from current expiry; trial or plan change → start now
    base = start if (ctx.user.plan == lic.plan and start > now) else now
    ctx.user.plan = lic.plan
    ctx.user.plan_expires_at = base + timedelta(days=lic.days)
    lic.redeemed_by, lic.redeemed_at = ctx.user.id, now
    audit(db, ctx.user.id, "redeem", lic.plan, client_ip(request))
    db.commit()
    return {"plan": ctx.user.plan, "plan_expires_at": ctx.user.plan_expires_at}


# ---------- me ----------

@router.get("/me")
def me(ctx: Ctx = Depends(current)):
    u = ctx.user
    return {"user_id": u.id, "login": u.login, "display_name": u.display_name, "plan": u.plan,
            "plan_expires_at": u.plan_expires_at, "plan_active": plan_active(u), "usage": quota(ctx.db, u)}


class MeIn(BaseModel):
    display_name: str = Field(max_length=60)


@router.patch("/me")
def update_me(body: MeIn, ctx: Ctx = Depends(current)):
    ctx.user.display_name = body.display_name.strip()
    ctx.db.commit()
    return {"display_name": ctx.user.display_name}


class DeleteIn(BaseModel):
    password: str


@router.post("/me/delete")
def delete_me(body: DeleteIn, ctx: Ctx = Depends(current)):
    """'Delete all my data' — removes the user and everything under their id."""
    if not verify_password(body.password, ctx.user.password_hash):
        raise err(401, "BAD_LOGIN", "Wrong password")
    ctx.db.delete(ctx.user)
    ctx.db.commit()
    return {"deleted": True}
