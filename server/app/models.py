"""Database tables. Every customer-owned row carries user_id and is only ever
queried with the user_id taken from the verified login token."""
import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, Boolean, DateTime, ForeignKey, Integer, LargeBinary, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .db import Base


def now() -> datetime:
    return datetime.now(timezone.utc)


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex}"


class User(Base):
    __tablename__ = "users"
    id: Mapped[str] = mapped_column(String(40), primary_key=True, default=lambda: new_id("user"))
    login: Mapped[str] = mapped_column(String(120), unique=True, index=True)  # phone or email
    password_hash: Mapped[str] = mapped_column(String(255))
    display_name: Mapped[str] = mapped_column(String(60), default="")
    plan: Mapped[str] = mapped_column(String(20), default="trial")
    plan_expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    banned: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)

    assistant: Mapped["AssistantSettings"] = relationship(back_populates="user", uselist=False, cascade="all, delete-orphan")


class License(Base):
    __tablename__ = "licenses"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    key_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    key_hint: Mapped[str] = mapped_column(String(12))  # last 4 chars, for admin support
    plan: Mapped[str] = mapped_column(String(20))
    days: Mapped[int] = mapped_column(Integer)
    note: Mapped[str] = mapped_column(String(200), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    redeemed_by: Mapped[str | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    redeemed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    revoked: Mapped[bool] = mapped_column(Boolean, default=False)


class Device(Base):
    __tablename__ = "devices"
    __table_args__ = (UniqueConstraint("user_id", "device_uid", name="uq_user_device"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    device_uid: Mapped[str] = mapped_column(String(128))
    device_type: Mapped[str] = mapped_column(String(10))  # phone | pc
    label: Mapped[str] = mapped_column(String(80), default="")
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    session_id: Mapped[str] = mapped_column(String(40), default="")  # only the latest login on this device is valid
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    deactivated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    last_ip: Mapped[str] = mapped_column(String(64), default="")


class AssistantSettings(Base):
    __tablename__ = "assistant_settings"
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    name: Mapped[str] = mapped_column(String(30), default="টমি")
    rename_count: Mapped[int] = mapped_column(Integer, default=0)
    theme: Mapped[str] = mapped_column(String(20), default="crimson")
    voice: Mapped[str] = mapped_column(String(20), default="aoede")
    ui_language: Mapped[str] = mapped_column(String(5), default="bn")
    speech_language: Mapped[str] = mapped_column(String(5), default="auto")
    # Wake-word "voice print" (few-shot embeddings), encrypted with the user's own key
    wakeword_blob: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True)
    wakeword_for_name: Mapped[str] = mapped_column(String(30), default="")
    extra: Mapped[dict] = mapped_column(JSON, default=dict)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now, onupdate=now)

    user: Mapped[User] = relationship(back_populates="assistant")


class Memory(Base):
    __tablename__ = "memories"
    id: Mapped[str] = mapped_column(String(40), primary_key=True, default=lambda: new_id("mem"))
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    kind: Mapped[str] = mapped_column(String(20))  # personal | shortcut
    content_enc: Mapped[bytes] = mapped_column(LargeBinary)  # encrypted with the user's own key
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now, onupdate=now)


class Trigger(Base):
    __tablename__ = "triggers"
    id: Mapped[str] = mapped_column(String(40), primary_key=True, default=lambda: new_id("trg"))
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    title: Mapped[str] = mapped_column(String(100))
    schedule: Mapped[str] = mapped_column(String(60))  # e.g. "daily 08:00"
    action: Mapped[str] = mapped_column(Text)          # natural-language instruction
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)


class UsageMonth(Base):
    __tablename__ = "usage_months"
    __table_args__ = (UniqueConstraint("user_id", "month", name="uq_usage_month"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    month: Mapped[str] = mapped_column(String(7))  # YYYY-MM
    ai_seconds: Mapped[int] = mapped_column(Integer, default=0)
    research: Mapped[int] = mapped_column(Integer, default=0)
    topup_minutes: Mapped[int] = mapped_column(Integer, default=0)


class LiveSession(Base):
    """One Gemini Live token = one reservation of minutes. Unused time is refunded when the app reports the end."""
    __tablename__ = "live_sessions"
    id: Mapped[str] = mapped_column(String(40), primary_key=True, default=lambda: new_id("live"))
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    reserved_seconds: Mapped[int] = mapped_column(Integer)
    used_seconds: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class AuditEvent(Base):
    """Security events used to spot account sharing (no private content)."""
    __tablename__ = "audit_events"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[str | None] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True, nullable=True)
    event: Mapped[str] = mapped_column(String(40))
    detail: Mapped[str] = mapped_column(String(300), default="")
    ip: Mapped[str] = mapped_column(String(64), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
