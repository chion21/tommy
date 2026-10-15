"""Shared business logic: quotas, memory safety, system prompt, Gemini calls."""
import json
import re
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import PLANS, VOICES, settings
from .models import AssistantSettings, AuditEvent, Memory, UsageMonth, User
from .security import decrypt_for

# ---------- usage / quota ----------

def month_key(dt: datetime | None = None) -> str:
    return (dt or datetime.now(timezone.utc)).strftime("%Y-%m")


def usage_row(db: Session, user_id: str) -> UsageMonth:
    row = db.scalar(select(UsageMonth).where(UsageMonth.user_id == user_id, UsageMonth.month == month_key()))
    if not row:
        row = UsageMonth(user_id=user_id, month=month_key(), ai_seconds=0, research=0, topup_minutes=0)
        db.add(row)
        db.flush()
    return row


def quota(db: Session, user: User) -> dict:
    limits = PLANS[user.plan]
    row = usage_row(db, user.id)
    total_sec = (limits["ai_minutes"] + row.topup_minutes) * 60
    return {
        "plan": user.plan,
        "ai_seconds_used": row.ai_seconds,
        "ai_seconds_total": total_sec,
        "ai_seconds_left": max(0, total_sec - row.ai_seconds),
        "research_used": row.research,
        "research_total": limits["research"],
        "memories_limit": limits["memories"],
    }


# ---------- memory safety ----------
_CARD = re.compile(r"(?:\d[ -]?){12,19}")
_SECRET_WORDS = re.compile(r"(password|passcode|pin\b|otp|cvv|পাসওয়ার্ড|পিন|ওটিপি|पासवर्ड)", re.IGNORECASE)


def is_sensitive(text: str) -> bool:
    return bool(_CARD.search(text) or _SECRET_WORDS.search(text))


def memory_context(db: Session, user_id: str, budget_chars: int = 1500) -> list[str]:
    """Newest memories first, trimmed to a small budget so every session stays cheap."""
    rows = db.scalars(select(Memory).where(Memory.user_id == user_id).order_by(Memory.updated_at.desc())).all()
    out, used = [], 0
    for m in rows:
        text = decrypt_for(user_id, m.content_enc).decode()
        line = f"[{m.kind}] {text}"
        if used + len(line) > budget_chars:
            break
        out.append(line)
        used += len(line)
    return out


# ---------- system prompt ----------
_LANG_RULE = {
    "auto": "Reply in the same language the user speaks (Bangla, English, Hindi, or mixed Banglish).",
    "bn": "Always reply in Bangla.",
    "en": "Always reply in English.",
    "hi": "Always reply in Hindi.",
}


def system_prompt(user: User, a: AssistantSettings, memories: list[str]) -> str:
    gender = VOICES.get(a.voice, {}).get("gender", "female")
    who = user.display_name or "the user"
    mem = "\n".join(f"- {m}" for m in memories) if memories else "- (nothing saved yet)"
    return f"""You are {a.name}, a warm, caring personal voice assistant ({gender} voice) for {who}.
Your name is {a.name}. Introduce yourself and answer to this name only.
{_LANG_RULE.get(a.speech_language, _LANG_RULE['auto'])}

Style:
- Speak sweetly and naturally, like a close friend. Keep spoken replies SHORT (1-2 sentences).
- When a task finishes, just confirm briefly ("হয়ে গেছে"). Put long content (research, lists) on screen via the show_text tool instead of reading it aloud.

Doing tasks:
- Use the provided tools to control the phone/PC. If a detail is missing, ask ONE short question (e.g. "কাকে মেসেজ পাঠাবো?").
- Before sending messages, calling, posting, paying, or deleting anything, read back what you will do and wait for a yes.
- Use saved memories to avoid asking again (contacts, folders, favourite apps). If the user corrects you, call save_memory.
- Never store passwords, PINs, OTPs, or card/bank numbers, even if asked; explain kindly.

Safety: be affectionate but respectful; do not produce sexual content; you are an AI assistant and say so if asked.

What you know about {who}:
{mem}
"""


# ---------- audit ----------

def audit(db: Session, user_id: str | None, event: str, detail: str = "", ip: str = "") -> None:
    db.add(AuditEvent(user_id=user_id, event=event, detail=detail[:300], ip=ip))


# ---------- Gemini (wrapped so tests can replace them) ----------

def _client(api_version: str | None = None):
    from google import genai
    opts = {"api_version": api_version} if api_version else None
    return genai.Client(api_key=settings.gemini_api_key, http_options=opts)


def create_live_token(system_instruction: str, voice_name: str, seconds: int) -> dict:
    """Short-lived, single-use Gemini Live token. The config (prompt, voice, model) is locked
    server-side, so a customer cannot reuse the token for anything else."""
    now = datetime.now(timezone.utc)
    client = _client("v1alpha")
    tok = client.auth_tokens.create(config={
        "uses": 1,
        "expire_time": now + timedelta(seconds=seconds + 60),
        "new_session_expire_time": now + timedelta(minutes=1),
        "live_connect_constraints": {
            "model": settings.live_model,
            "config": {
                "response_modalities": ["AUDIO"],
                "system_instruction": system_instruction,
                "speech_config": {"voice_config": {"prebuilt_voice_config": {"voice_name": voice_name}}},
                "input_audio_transcription": {},
                "output_audio_transcription": {},
                "context_window_compression": {"sliding_window": {}},
            },
        },
        "http_options": {"api_version": "v1alpha"},
    })
    return {"token": tok.name, "model": settings.live_model}


def research(query: str, lang: str) -> str:
    """Cheap text model + Google Search; result is shown as text, not spoken."""
    from google.genai import types
    client = _client()
    rule = _LANG_RULE.get(lang, _LANG_RULE["auto"])
    resp = client.models.generate_content(
        model=settings.text_model,
        contents=f"{rule}\nResearch and give a clear, well-organised answer with key points:\n{query}",
        config=types.GenerateContentConfig(tools=[types.Tool(google_search=types.GoogleSearch())]),
    )
    return resp.text or ""


def extract_memories(transcript: str) -> list[dict]:
    """Pull durable facts out of a finished conversation. Returns [{kind, text}]."""
    from google.genai import types
    client = _client()
    prompt = (
        "From this conversation between a user and their assistant, list durable facts worth remembering "
        "for future help: personal preferences (kind=personal) and task shortcuts like which contact/folder/app "
        "a word refers to (kind=shortcut). Skip one-off requests, passwords, PINs, OTPs, card or bank numbers. "
        'Return JSON: [{"kind": "personal"|"shortcut", "text": "..."}]. Return [] if nothing.\n\n' + transcript
    )
    resp = client.models.generate_content(
        model=settings.text_model, contents=prompt,
        config=types.GenerateContentConfig(response_mime_type="application/json"),
    )
    try:
        data = json.loads(resp.text or "[]")
    except json.JSONDecodeError:
        return []
    return [d for d in data if isinstance(d, dict) and d.get("kind") in ("personal", "shortcut") and d.get("text")]
