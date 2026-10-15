import base64
import hashlib
import hmac
import secrets
from datetime import datetime, timedelta, timezone

import jwt
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from .config import settings

# ---------- passwords (scrypt, no extra dependency) ----------

def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    dk = hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=1, dklen=32)
    return "scrypt$" + base64.b64encode(salt).decode() + "$" + base64.b64encode(dk).decode()


def verify_password(password: str, stored: str) -> bool:
    try:
        _, salt_b64, dk_b64 = stored.split("$")
        salt, dk = base64.b64decode(salt_b64), base64.b64decode(dk_b64)
    except ValueError:
        return False
    test = hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=1, dklen=32)
    return hmac.compare_digest(test, dk)


# ---------- login tokens ----------

def make_token(user_id: str, device_id: int, session_id: str) -> tuple[str, datetime]:
    exp = datetime.now(timezone.utc) + timedelta(hours=settings.token_hours)
    payload = {"sub": user_id, "dev": device_id, "sid": session_id, "exp": exp}
    return jwt.encode(payload, settings.jwt_secret, algorithm="HS256"), exp


def read_token(token: str) -> dict:
    return jwt.decode(token, settings.jwt_secret, algorithms=["HS256"])


# ---------- license keys ----------
_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O/1/I to avoid typos


def new_license_key() -> str:
    groups = ["".join(secrets.choice(_ALPHABET) for _ in range(4)) for _ in range(3)]
    return "TOMMY-" + "-".join(groups)


def normalize_key(key: str) -> str:
    return key.strip().upper().replace(" ", "")


def hash_key(key: str) -> str:
    return hashlib.sha256((settings.jwt_secret + normalize_key(key)).encode()).hexdigest()


# ---------- per-user encryption ----------

def user_cipher(user_id: str) -> Fernet:
    """Each customer gets their own encryption key, derived from the server master key + their id."""
    hkdf = HKDF(algorithm=hashes.SHA256(), length=32, salt=b"tommy-user-data", info=user_id.encode())
    key = hkdf.derive(settings.master_key.encode())
    return Fernet(base64.urlsafe_b64encode(key))


def encrypt_for(user_id: str, data: bytes) -> bytes:
    return user_cipher(user_id).encrypt(data)


def decrypt_for(user_id: str, blob: bytes) -> bytes:
    return user_cipher(user_id).decrypt(blob)
