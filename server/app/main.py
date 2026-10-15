from contextlib import asynccontextmanager

from fastapi import FastAPI

from .config import settings
from .db import Base, engine
from .routers import admin, ai, assistant, auth

@asynccontextmanager
async def lifespan(_app: FastAPI):
    if (settings.jwt_secret.startswith("dev-only") or settings.master_key.startswith("dev-only")) \
            and not settings.database_url.startswith("sqlite"):
        raise RuntimeError("Set JWT_SECRET and MASTER_KEY before running in production")
    Base.metadata.create_all(engine)
    yield


app = FastAPI(title="Tommy API", version="0.1.0", lifespan=lifespan)
app.include_router(auth.router)
app.include_router(assistant.router)
app.include_router(ai.router)
app.include_router(admin.router)


@app.get("/health")
def health():
    return {"ok": True, "ai_configured": bool(settings.gemini_api_key)}
