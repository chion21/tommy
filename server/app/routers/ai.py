"""Gemini Live session tokens, research, and usage."""
from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from ..config import VOICES, settings
from ..deps import Ctx, current, err, require_active_plan
from ..models import LiveSession
from ..services import create_live_token, memory_context, quota, research, system_prompt, usage_row

router = APIRouter(tags=["ai"])


@router.get("/usage")
def usage(ctx: Ctx = Depends(current)):
    q = quota(ctx.db, ctx.user)
    ctx.db.commit()
    return q


@router.post("/live/session")
def start_live(ctx: Ctx = Depends(require_active_plan)):
    """Reserve minutes from the user's quota and hand back a single-use Gemini Live token
    with the prompt, voice and model locked in. The real API key never leaves the server."""
    if not settings.gemini_api_key:
        raise err(503, "AI_NOT_CONFIGURED", "AI is not configured on the server")
    db, user = ctx.db, ctx.user
    q = quota(db, user)
    if q["ai_seconds_left"] < 30:
        raise err(402, "QUOTA_EXCEEDED", "AI minutes finished for this month. Local commands still work")
    reserve = min(settings.max_session_minutes * 60, q["ai_seconds_left"])

    a = user.assistant
    prompt = system_prompt(user, a, memory_context(db, user.id))
    tok = create_live_token(prompt, VOICES[a.voice]["gemini"], reserve)

    usage_row(db, user.id).ai_seconds += reserve  # charge up front; refunded at /end
    s = LiveSession(user_id=user.id, reserved_seconds=reserve)
    db.add(s)
    db.commit()
    return {"session_id": s.id, "token": tok["token"], "model": tok["model"], "max_seconds": reserve,
            "assistant_name": a.name, "voice": a.voice}


class EndIn(BaseModel):
    used_seconds: int = Field(ge=0)


@router.post("/live/session/{session_id}/end")
def end_live(session_id: str, body: EndIn, ctx: Ctx = Depends(current)):
    s = ctx.db.get(LiveSession, session_id)
    if not s or s.user_id != ctx.user.id:
        raise err(404, "NOT_FOUND", "Session not found")
    if s.used_seconds is None:
        used = min(body.used_seconds, s.reserved_seconds)  # the app can only lower the charge, never raise its quota
        s.used_seconds = used
        row = usage_row(ctx.db, ctx.user.id)
        row.ai_seconds = max(0, row.ai_seconds - (s.reserved_seconds - used))
        ctx.db.commit()
    return quota(ctx.db, ctx.user)


class ResearchIn(BaseModel):
    query: str = Field(min_length=2, max_length=2000)


@router.post("/research")
def do_research(body: ResearchIn, ctx: Ctx = Depends(require_active_plan)):
    if not settings.gemini_api_key:
        raise err(503, "AI_NOT_CONFIGURED", "AI is not configured on the server")
    q = quota(ctx.db, ctx.user)
    if q["research_used"] >= q["research_total"]:
        raise err(402, "RESEARCH_LIMIT", "Research limit reached for this month")
    text = research(body.query, ctx.user.assistant.speech_language)
    usage_row(ctx.db, ctx.user.id).research += 1
    ctx.db.commit()
    return {"text": text, "usage": quota(ctx.db, ctx.user)}
