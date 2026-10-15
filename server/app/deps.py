from dataclasses import dataclass
from datetime import datetime, timezone

import jwt
from fastapi import Depends, Header, HTTPException, Request
from sqlalchemy.orm import Session

from .config import settings
from .db import get_db
from .models import Device, User
from .security import read_token


def err(status: int, code: str, message: str) -> HTTPException:
    """All errors carry a stable code the app can translate into bn/en/hi."""
    return HTTPException(status_code=status, detail={"code": code, "message": message})


@dataclass
class Ctx:
    user: User
    device: Device
    db: Session


def client_ip(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for", "")
    return fwd.split(",")[0].strip() if fwd else (request.client.host if request.client else "")


def current(request: Request, authorization: str = Header(default=""), db: Session = Depends(get_db)) -> Ctx:
    if not authorization.lower().startswith("bearer "):
        raise err(401, "NO_TOKEN", "Login required")
    try:
        claims = read_token(authorization[7:])
    except jwt.ExpiredSignatureError:
        raise err(401, "TOKEN_EXPIRED", "Session expired, please refresh")
    except jwt.PyJWTError:
        raise err(401, "BAD_TOKEN", "Invalid session")

    # user_id comes ONLY from the verified token — never from the request body/URL.
    user = db.get(User, claims["sub"])
    device = db.get(Device, claims["dev"])
    if not user or not device or device.user_id != user.id:
        raise err(401, "BAD_TOKEN", "Invalid session")
    if user.banned:
        raise err(403, "BANNED", "Account blocked")
    if not device.active:
        raise err(401, "DEVICE_REMOVED", "This device was removed from the account")
    if device.session_id != claims["sid"]:
        raise err(401, "SESSION_REPLACED", "Logged in somewhere else on this device type")

    device.last_seen_at = datetime.now(timezone.utc)
    device.last_ip = client_ip(request)
    db.commit()
    return Ctx(user=user, device=device, db=db)


def plan_active(user: User) -> bool:
    exp = user.plan_expires_at
    if exp.tzinfo is None:
        exp = exp.replace(tzinfo=timezone.utc)
    return exp > datetime.now(timezone.utc)


def require_active_plan(ctx: Ctx = Depends(current)) -> Ctx:
    if not plan_active(ctx.user):
        raise err(402, "PLAN_EXPIRED", "Your plan has expired")
    return ctx


def require_admin(x_admin_key: str = Header(default="")) -> None:
    if not settings.admin_api_key or x_admin_key != settings.admin_api_key:
        raise err(403, "NOT_ADMIN", "Admin key required")
