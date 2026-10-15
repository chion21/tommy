import base64
import os
from datetime import datetime, timedelta, timezone

os.environ["ADMIN_API_KEY"] = "admin-test"
os.environ["GEMINI_API_KEY"] = "fake-key"

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import sessionmaker

from app import db as dbmod
from app import services
from app.db import Base, make_engine
from app.main import app
from app.models import Memory, User
from app.routers import ai as ai_router
from app.routers import assistant as as_router

ADMIN = {"X-Admin-Key": "admin-test"}


@pytest.fixture()
def client(tmp_path, monkeypatch):
    engine = make_engine(f"sqlite:///{tmp_path}/t.db")
    Base.metadata.create_all(engine)
    TestSession = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)

    def _db():
        s = TestSession()
        try:
            yield s
        finally:
            s.close()

    app.dependency_overrides[dbmod.get_db] = _db
    monkeypatch.setattr(ai_router, "create_live_token", lambda p, v, s: {"token": "auth_tokens/abc", "model": "m"})
    monkeypatch.setattr(ai_router, "research", lambda q, l: "result")
    monkeypatch.setattr(as_router, "extract_memories", lambda t: [
        {"kind": "shortcut", "text": "রাজ মানে WhatsApp-এর Raj Bhai Office"},
        {"kind": "personal", "text": "my card is 4111 1111 1111 1111"},
    ])
    with TestClient(app) as c:
        c.Session = TestSession
        yield c
    app.dependency_overrides.clear()


def register_login(c, login="01711000000", dev="phone-uid-0001", dtype="phone", **kw):
    c.post("/auth/register", json={"login": login, "password": "secret123", "display_name": "রাকিব"})
    r = c.post("/auth/login", json={"login": login, "password": "secret123", "device_uid": dev,
                                    "device_type": dtype, "label": dev, **kw})
    return r


def auth(r):
    return {"Authorization": f"Bearer {r.json()['token']}"}


def test_register_login_me(client):
    r = register_login(client)
    assert r.status_code == 200
    me = client.get("/me", headers=auth(r)).json()
    assert me["plan"] == "trial" and me["plan_active"] and me["display_name"] == "রাকিব"


def test_wrong_password(client):
    register_login(client)
    r = client.post("/auth/login", json={"login": "01711000000", "password": "nope12", "device_uid": "x" * 10,
                                         "device_type": "phone"})
    assert r.json()["detail"]["code"] == "BAD_LOGIN"


def test_one_phone_one_pc_and_swap_limit(client):
    r1 = register_login(client)
    pc = client.post("/auth/login", json={"login": "01711000000", "password": "secret123",
                                          "device_uid": "pc-uid-00001", "device_type": "pc"})
    assert pc.status_code == 200  # 1 phone + 1 PC allowed

    second_phone = dict(login="01711000000", password="secret123", device_uid="phone-uid-0002", device_type="phone")
    r = client.post("/auth/login", json=second_phone)
    assert r.status_code == 409 and r.json()["detail"]["code"] == "DEVICE_LIMIT"

    r = client.post("/auth/login", json={**second_phone, "replace_device": True})
    assert r.status_code == 200
    # old phone is now kicked out
    assert client.get("/me", headers=auth(r1)).json()["detail"]["code"] == "DEVICE_REMOVED"

    client.post("/auth/login", json={**second_phone, "device_uid": "phone-uid-0003", "replace_device": True})
    r = client.post("/auth/login", json={**second_phone, "device_uid": "phone-uid-0004", "replace_device": True})
    assert r.status_code == 429 and r.json()["detail"]["code"] == "SWAP_LIMIT"


def test_relogin_same_device_replaces_session(client):
    r1 = register_login(client)
    r2 = client.post("/auth/login", json={"login": "01711000000", "password": "secret123",
                                          "device_uid": "phone-uid-0001", "device_type": "phone"})
    assert client.get("/me", headers=auth(r1)).json()["detail"]["code"] == "SESSION_REPLACED"
    assert client.get("/me", headers=auth(r2)).status_code == 200


def test_refresh(client):
    r = register_login(client)
    r2 = client.post("/auth/refresh", json={"token": r.json()["token"]})
    assert r2.status_code == 200 and client.get("/me", headers=auth(r2)).status_code == 200


def test_license_redeem_once(client):
    keys = client.post("/admin/licenses", headers=ADMIN, json={"plan": "yearly", "days": 365, "count": 1}).json()["keys"]
    assert keys[0].startswith("TOMMY-")
    r = register_login(client)
    out = client.post("/license/redeem", headers=auth(r), json={"key": keys[0].lower()}).json()
    assert out["plan"] == "yearly"
    r2 = register_login(client, login="friend@mail.com", dev="friend-phone-01")
    again = client.post("/license/redeem", headers=auth(r2), json={"key": keys[0]})
    assert again.json()["detail"]["code"] == "KEY_USED"
    assert client.post("/license/redeem", headers=auth(r2), json={"key": "TOMMY-AAAA-BBBB-CCCC"}).json()["detail"]["code"] == "BAD_KEY"


def test_admin_requires_key(client):
    assert client.get("/admin/users").status_code == 403


def test_rename_limit_and_wakeword_reset(client):
    h = auth(register_login(client))
    assert client.post("/assistant/rename", headers=h, json={"name": "র"}).json()["detail"]["code"] == "NAME_TOO_SHORT"
    tpl = base64.b64encode(b"embeddings").decode()
    client.put("/assistant/wakeword", headers=h, json={"name": "টমি", "template_b64": tpl})
    assert client.get("/assistant", headers=h).json()["wakeword_ready"]
    names = ["রিয়া", "মায়া", "Nova", "जया", "সারা"]
    for n in names:
        out = client.post("/assistant/rename", headers=h, json={"name": n}).json()
        assert out["name"] == n
    assert out["renames_left"] == 0 and not out["wakeword_ready"]
    r = client.post("/assistant/rename", headers=h, json={"name": "Luna"})
    assert r.json()["detail"]["code"] == "RENAME_LIMIT"


def test_prefs_validation(client):
    h = auth(register_login(client))
    ok = client.patch("/assistant", headers=h, json={"theme": "violet", "voice": "puck", "ui_language": "en",
                                                      "speech_language": "auto"}).json()
    assert ok["theme"] == "violet" and ok["voice"] == "puck"
    bad = client.patch("/assistant", headers=h, json={"ui_language": "fr"})
    assert bad.json()["detail"]["code"] == "BAD_OPTION"


def test_memory_isolation_encryption_and_sensitive(client):
    ha = auth(register_login(client))
    hb = auth(register_login(client, login="b@mail.com", dev="b-phone-uid-01"))
    m = client.post("/memory", headers=ha, json={"kind": "personal", "text": "আমাকে ভাইয়া বলে ডাকবে"}).json()
    # user B can't see, edit or delete A's memory
    assert client.get("/memory", headers=hb).json() == []
    assert client.delete(f"/memory/{m['id']}", headers=hb).status_code == 404
    assert client.put(f"/memory/{m['id']}", headers=hb, json={"kind": "personal", "text": "x"}).status_code == 404
    # stored encrypted
    with client.Session() as s:
        row = s.get(Memory, m["id"])
        assert "ভাইয়া".encode() not in row.content_enc
    bad = client.post("/memory", headers=ha, json={"kind": "personal", "text": "my password is hunter2"})
    assert bad.json()["detail"]["code"] == "SENSITIVE"


def test_memory_extract_skips_sensitive(client):
    h = auth(register_login(client))
    saved = client.post("/memory/extract", headers=h, json={"transcript": "..."}).json()["saved"]
    assert len(saved) == 1 and saved[0]["kind"] == "shortcut"


def test_memory_limit(client):
    h = auth(register_login(client))  # trial = 20
    for i in range(20):
        assert client.post("/memory", headers=h, json={"kind": "personal", "text": f"fact {i}"}).status_code == 200
    assert client.post("/memory", headers=h, json={"kind": "personal", "text": "one more"}).json()["detail"]["code"] == "MEMORY_LIMIT"


def test_live_session_quota_and_refund(client):
    h = auth(register_login(client))
    s = client.post("/live/session", headers=h).json()
    assert s["token"] == "auth_tokens/abc" and s["max_seconds"] == 600
    assert client.get("/usage", headers=h).json()["ai_seconds_used"] == 600
    after = client.post(f"/live/session/{s['session_id']}/end", headers=h, json={"used_seconds": 90}).json()
    assert after["ai_seconds_used"] == 90
    # reporting twice or reporting more can't change it
    again = client.post(f"/live/session/{s['session_id']}/end", headers=h, json={"used_seconds": 0}).json()
    assert again["ai_seconds_used"] == 90
    # trial = 30 min total; use it up
    for _ in range(3):
        client.post("/live/session", headers=h)
    r = client.post("/live/session", headers=h)
    assert r.json()["detail"]["code"] == "QUOTA_EXCEEDED"


def test_expired_plan_blocks_ai(client):
    r = register_login(client)
    with client.Session() as s:
        u = s.get(User, r.json()["user_id"])
        u.plan_expires_at = datetime.now(timezone.utc) - timedelta(days=1)
        s.commit()
    assert client.post("/live/session", headers=auth(r)).json()["detail"]["code"] == "PLAN_EXPIRED"


def test_system_prompt_uses_name_and_memories(client):
    h = auth(register_login(client))
    client.post("/assistant/rename", headers=h, json={"name": "রিয়া"})
    client.post("/memory", headers=h, json={"kind": "shortcut", "text": "গান মানে Spotify"})
    captured = {}
    import app.routers.ai as air
    orig = air.create_live_token
    air.create_live_token = lambda p, v, s: captured.update(p=p, v=v) or {"token": "t", "model": "m"}
    try:
        client.post("/live/session", headers=h)
    finally:
        air.create_live_token = orig
    assert "You are রিয়া" in captured["p"] and "Spotify" in captured["p"] and captured["v"] == "Aoede"


def test_delete_account_removes_everything(client):
    r = register_login(client)
    h = auth(r)
    client.post("/memory", headers=h, json={"kind": "personal", "text": "x fact"})
    assert client.post("/me/delete", headers=h, json={"password": "secret123"}).json()["deleted"]
    with client.Session() as s:
        assert s.get(User, r.json()["user_id"]) is None
        assert s.query(Memory).count() == 0


def test_admin_users_hide_private_data(client):
    h = auth(register_login(client))
    client.post("/memory", headers=h, json={"kind": "personal", "text": "secret-ish fact"})
    data = client.get("/admin/users", headers=ADMIN).json()
    assert "secret-ish" not in str(data) and data[0]["active_devices"] == 1
