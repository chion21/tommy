"""Assistant personalisation (name, theme, voice, language), wake word, memory, triggers."""
import base64

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import func, select

from ..config import PLANS, SPEECH_LANGUAGES, THEMES, UI_LANGUAGES, VOICES, settings
from ..deps import Ctx, current, err, require_active_plan
from ..models import Memory, Trigger
from ..security import decrypt_for, encrypt_for
from ..services import extract_memories, is_sensitive

router = APIRouter(tags=["assistant"])


def _settings_out(ctx: Ctx) -> dict:
    a = ctx.user.assistant
    return {
        "name": a.name, "renames_left": max(0, settings.max_renames - a.rename_count),
        "theme": a.theme, "voice": a.voice, "ui_language": a.ui_language, "speech_language": a.speech_language,
        "wakeword_ready": bool(a.wakeword_blob) and a.wakeword_for_name == a.name,
        "options": {"themes": THEMES, "voices": {k: v["gender"] for k, v in VOICES.items()},
                    "ui_languages": UI_LANGUAGES, "speech_languages": SPEECH_LANGUAGES},
    }


@router.get("/assistant")
def get_assistant(ctx: Ctx = Depends(current)):
    return _settings_out(ctx)


class PrefsIn(BaseModel):
    theme: str | None = None
    voice: str | None = None
    ui_language: str | None = None
    speech_language: str | None = None


@router.patch("/assistant")
def update_prefs(body: PrefsIn, ctx: Ctx = Depends(current)):
    a = ctx.user.assistant
    checks = [("theme", THEMES), ("voice", list(VOICES)), ("ui_language", UI_LANGUAGES),
              ("speech_language", SPEECH_LANGUAGES)]
    for field, allowed in checks:
        val = getattr(body, field)
        if val is not None:
            if val not in allowed:
                raise err(422, "BAD_OPTION", f"{field} must be one of {allowed}")
            setattr(a, field, val)
    ctx.db.commit()
    return _settings_out(ctx)


class RenameIn(BaseModel):
    name: str = Field(min_length=1, max_length=30)


def _valid_name(name: str) -> bool:
    letters = [c for c in name if c.isalpha()]  # Bangla vowel signs are not isalpha, so this counts base letters
    return len(letters) >= 2 and len(name) <= 20


@router.post("/assistant/rename")
def rename(body: RenameIn, ctx: Ctx = Depends(current)):
    a = ctx.user.assistant
    name = " ".join(body.name.split())
    if not _valid_name(name):
        raise err(422, "NAME_TOO_SHORT", "Name must have at least 2 letters (max 20 characters)")
    if name == a.name:
        return _settings_out(ctx)
    if a.rename_count >= settings.max_renames:
        raise err(429, "RENAME_LIMIT", "Name can be changed at most 5 times")
    a.name = name
    a.rename_count += 1
    a.wakeword_blob, a.wakeword_for_name = None, ""  # new name → record "হেই <name>" again
    ctx.db.commit()
    return _settings_out(ctx)


class WakewordIn(BaseModel):
    name: str
    template_b64: str = Field(max_length=2_000_000)  # few-shot embeddings from the device, not raw audio


@router.put("/assistant/wakeword")
def save_wakeword(body: WakewordIn, ctx: Ctx = Depends(current)):
    a = ctx.user.assistant
    if body.name != a.name:
        raise err(409, "NAME_MISMATCH", "Wake word is for a different name")
    a.wakeword_blob = encrypt_for(ctx.user.id, base64.b64decode(body.template_b64))
    a.wakeword_for_name = a.name
    ctx.db.commit()
    return {"wakeword_ready": True}


@router.get("/assistant/wakeword")
def get_wakeword(ctx: Ctx = Depends(current)):
    a = ctx.user.assistant
    if not a.wakeword_blob or a.wakeword_for_name != a.name:
        raise err(404, "NO_WAKEWORD", "Wake word not recorded yet")
    return {"name": a.name, "template_b64": base64.b64encode(decrypt_for(ctx.user.id, a.wakeword_blob)).decode()}


# ---------- memory ----------

class MemoryIn(BaseModel):
    kind: str = Field(pattern="^(personal|shortcut)$")
    text: str = Field(min_length=1, max_length=500)


def _mem_out(ctx: Ctx, m: Memory) -> dict:
    return {"id": m.id, "kind": m.kind, "text": decrypt_for(ctx.user.id, m.content_enc).decode(),
            "updated_at": m.updated_at}


def _check_mem_limit(ctx: Ctx, adding: int = 1) -> None:
    limit = PLANS[ctx.user.plan]["memories"]
    if limit is None:
        return
    count = ctx.db.scalar(select(func.count()).select_from(Memory).where(Memory.user_id == ctx.user.id)) or 0
    if count + adding > limit:
        raise err(429, "MEMORY_LIMIT", f"Memory is full ({limit}). Delete some or upgrade to Premium")


@router.get("/memory")
def list_memory(ctx: Ctx = Depends(current)):
    rows = ctx.db.scalars(select(Memory).where(Memory.user_id == ctx.user.id).order_by(Memory.updated_at.desc())).all()
    return [_mem_out(ctx, m) for m in rows]


@router.post("/memory")
def add_memory(body: MemoryIn, ctx: Ctx = Depends(current)):
    if is_sensitive(body.text):
        raise err(422, "SENSITIVE", "Passwords, PINs, OTPs and card/bank numbers are never saved")
    _check_mem_limit(ctx)
    m = Memory(user_id=ctx.user.id, kind=body.kind, content_enc=encrypt_for(ctx.user.id, body.text.encode()))
    ctx.db.add(m)
    ctx.db.commit()
    return _mem_out(ctx, m)


def _own_memory(ctx: Ctx, mem_id: str) -> Memory:
    m = ctx.db.get(Memory, mem_id)
    if not m or m.user_id != ctx.user.id:  # someone else's memory looks exactly like a missing one
        raise err(404, "NOT_FOUND", "Memory not found")
    return m


@router.put("/memory/{mem_id}")
def edit_memory(mem_id: str, body: MemoryIn, ctx: Ctx = Depends(current)):
    if is_sensitive(body.text):
        raise err(422, "SENSITIVE", "Passwords, PINs, OTPs and card/bank numbers are never saved")
    m = _own_memory(ctx, mem_id)
    m.kind, m.content_enc = body.kind, encrypt_for(ctx.user.id, body.text.encode())
    ctx.db.commit()
    return _mem_out(ctx, m)


@router.delete("/memory/{mem_id}")
def delete_memory(mem_id: str, ctx: Ctx = Depends(current)):
    ctx.db.delete(_own_memory(ctx, mem_id))
    ctx.db.commit()
    return {"deleted": True}


class ExtractIn(BaseModel):
    transcript: str = Field(min_length=1, max_length=20_000)


@router.post("/memory/extract")
def extract(body: ExtractIn, ctx: Ctx = Depends(require_active_plan)):
    """Called by the app after a conversation ends. Saves new durable facts, skipping sensitive ones."""
    found = [f for f in extract_memories(body.transcript) if not is_sensitive(f["text"])]
    limit = PLANS[ctx.user.plan]["memories"]
    existing = {decrypt_for(ctx.user.id, m.content_enc).decode().strip().lower()
                for m in ctx.db.scalars(select(Memory).where(Memory.user_id == ctx.user.id))}
    count = len(existing)
    saved = []
    for f in found:
        text = f["text"].strip()[:500]
        if text.lower() in existing or (limit is not None and count >= limit):
            continue
        m = Memory(user_id=ctx.user.id, kind=f["kind"], content_enc=encrypt_for(ctx.user.id, text.encode()))
        ctx.db.add(m)
        existing.add(text.lower())
        count += 1
        saved.append({"kind": f["kind"], "text": text})
    ctx.db.commit()
    return {"saved": saved}


# ---------- triggers ----------

class TriggerIn(BaseModel):
    title: str = Field(min_length=1, max_length=100)
    schedule: str = Field(min_length=1, max_length=60)
    action: str = Field(min_length=1, max_length=1000)
    enabled: bool = True


@router.get("/triggers")
def list_triggers(ctx: Ctx = Depends(current)):
    rows = ctx.db.scalars(select(Trigger).where(Trigger.user_id == ctx.user.id)).all()
    return [{"id": t.id, "title": t.title, "schedule": t.schedule, "action": t.action, "enabled": t.enabled}
            for t in rows]


@router.post("/triggers")
def add_trigger(body: TriggerIn, ctx: Ctx = Depends(current)):
    t = Trigger(user_id=ctx.user.id, **body.model_dump())
    ctx.db.add(t)
    ctx.db.commit()
    return {"id": t.id, **body.model_dump()}


@router.delete("/triggers/{trg_id}")
def delete_trigger(trg_id: str, ctx: Ctx = Depends(current)):
    t = ctx.db.get(Trigger, trg_id)
    if not t or t.user_id != ctx.user.id:
        raise err(404, "NOT_FOUND", "Trigger not found")
    ctx.db.delete(t)
    ctx.db.commit()
    return {"deleted": True}
