"""Central settings. Everything secret comes from environment variables (never hard-coded)."""
import os
from dataclasses import dataclass, field


def _load_dotenv() -> None:
    """Read server/.env (used when running on a laptop without Docker). Real env vars win."""
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.split(" #")[0].strip())


_load_dotenv()


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


@dataclass(frozen=True)
class Settings:
    database_url: str = field(default_factory=lambda: _env("DATABASE_URL", "sqlite:///./tommy.db"))
    jwt_secret: str = field(default_factory=lambda: _env("JWT_SECRET", "dev-only-change-me-this-is-not-a-real-secret"))
    # 32-byte urlsafe base64 key; used to derive a separate encryption key per user
    master_key: str = field(default_factory=lambda: _env("MASTER_KEY", "dev-only-master-key-change-me-please"))
    admin_api_key: str = field(default_factory=lambda: _env("ADMIN_API_KEY", ""))
    gemini_api_key: str = field(default_factory=lambda: _env("GEMINI_API_KEY", ""))
    live_model: str = field(default_factory=lambda: _env("LIVE_MODEL", "gemini-3.8-live"))
    text_model: str = field(default_factory=lambda: _env("TEXT_MODEL", "gemini-3.8-flash"))

    token_hours: int = 24              # app must refresh daily; app allows 3 offline days itself
    max_renames: int = 5
    device_swaps_per_30d: int = 2
    trial_days: int = 7
    max_session_minutes: int = 10      # one Gemini Live token covers at most this long


settings = Settings()

# Plan limits. "ai_minutes" is per calendar month (trial: whole trial).
PLANS: dict[str, dict] = {
    "trial":   {"ai_minutes": 30,   "research": 5,   "memories": 20,   "live_voice": True},
    "yearly":  {"ai_minutes": 200,  "research": 10,  "memories": 100,  "live_voice": True},
    "premium": {"ai_minutes": 500,  "research": 50,  "memories": None, "live_voice": True},
}

THEMES = ["crimson", "violet", "aqua", "sakura", "gold", "emerald"]

# Gemini prebuilt voices — confirm Bangla quality in testing and swap names here if needed.
VOICES = {
    "aoede": {"gemini": "Aoede", "gender": "female"},
    "kore":  {"gemini": "Kore",  "gender": "female"},
    "leda":  {"gemini": "Leda",  "gender": "female"},
    "puck":  {"gemini": "Puck",  "gender": "male"},
    "charon": {"gemini": "Charon", "gender": "male"},
}

UI_LANGUAGES = ["bn", "en", "hi"]
SPEECH_LANGUAGES = ["auto", "bn", "en", "hi"]
DEVICE_TYPES = ["phone", "pc"]
