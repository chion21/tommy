"""Owner-only panel API (header X-Admin-Key). Shows licences, devices and usage — never private memories."""
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..config import PLANS
from ..db import get_db
from ..deps import err, require_admin
from ..models import AuditEvent, Device, License, User
from ..security import hash_key, new_license_key
from ..services import quota

router = APIRouter(prefix="/admin", tags=["admin"], dependencies=[Depends(require_admin)])


class NewLicenses(BaseModel):
    plan: str
    days: int = Field(ge=1, le=3650)
    count: int = Field(default=1, ge=1, le=500)
    note: str = ""


@router.post("/licenses")
def create_licenses(body: NewLicenses, db: Session = Depends(get_db)):
    if body.plan not in PLANS or body.plan == "trial":
        raise err(422, "BAD_PLAN", "plan must be yearly or premium")
    keys = []
    for _ in range(body.count):
        key = new_license_key()
        db.add(License(key_hash=hash_key(key), key_hint=key[-4:], plan=body.plan, days=body.days, note=body.note))
        keys.append(key)
    db.commit()
    return {"keys": keys, "note": "Keys are shown only once — save them now."}


class RevokeIn(BaseModel):
    key: str


@router.post("/licenses/revoke")
def revoke(body: RevokeIn, db: Session = Depends(get_db)):
    lic = db.scalar(select(License).where(License.key_hash == hash_key(body.key)))
    if not lic:
        raise err(404, "NOT_FOUND", "Key not found")
    lic.revoked = True
    if lic.redeemed_by:
        u = db.get(User, lic.redeemed_by)
        if u:
            u.plan_expires_at = datetime.now(timezone.utc)
    db.commit()
    return {"revoked": True}


def _flags(db: Session, user_id: str) -> list[str]:
    week = datetime.now(timezone.utc) - timedelta(days=7)
    ips = db.scalar(select(func.count(func.distinct(AuditEvent.ip))).where(
        AuditEvent.user_id == user_id, AuditEvent.event == "login", AuditEvent.created_at >= week)) or 0
    swaps = db.scalar(select(func.count()).select_from(AuditEvent).where(
        AuditEvent.user_id == user_id, AuditEvent.event.in_(["device_replaced", "swap_limit_hit"]),
        AuditEvent.created_at >= week)) or 0
    flags = []
    if ips > 5:
        flags.append(f"{ips} different IPs this week")
    if swaps >= 3:
        flags.append(f"{swaps} device changes this week")
    return flags


@router.get("/users")
def users(db: Session = Depends(get_db), limit: int = 100, offset: int = 0):
    out = []
    for u in db.scalars(select(User).order_by(User.created_at.desc()).limit(limit).offset(offset)):
        devices = db.scalar(select(func.count()).select_from(Device).where(
            Device.user_id == u.id, Device.active.is_(True))) or 0
        out.append({"id": u.id, "login": u.login, "plan": u.plan, "plan_expires_at": u.plan_expires_at,
                    "banned": u.banned, "active_devices": devices, "usage": quota(db, u),
                    "flags": _flags(db, u.id)})
    db.commit()
    return out


def _user(db: Session, user_id: str) -> User:
    u = db.get(User, user_id)
    if not u:
        raise err(404, "NOT_FOUND", "User not found")
    return u


@router.post("/users/{user_id}/ban")
def ban(user_id: str, db: Session = Depends(get_db)):
    _user(db, user_id).banned = True
    db.commit()
    return {"banned": True}


@router.post("/users/{user_id}/unban")
def unban(user_id: str, db: Session = Depends(get_db)):
    _user(db, user_id).banned = False
    db.commit()
    return {"banned": False}


@router.post("/users/{user_id}/reset-devices")
def reset_devices(user_id: str, db: Session = Depends(get_db)):
    """Support action: customer lost their phone etc. Frees both slots without counting as swaps."""
    for d in db.scalars(select(Device).where(Device.user_id == user_id, Device.active.is_(True))):
        d.active, d.session_id = False, ""
    db.commit()
    return {"reset": True}


@router.get("/stats")
def stats(db: Session = Depends(get_db)):
    now = datetime.now(timezone.utc)
    by_plan = dict(db.execute(select(User.plan, func.count()).where(User.plan_expires_at > now)
                              .group_by(User.plan)).all())
    return {"users": db.scalar(select(func.count()).select_from(User)), "active_by_plan": by_plan,
            "unused_keys": db.scalar(select(func.count()).select_from(License).where(
                License.redeemed_by.is_(None), License.revoked.is_(False)))}
