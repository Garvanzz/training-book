from __future__ import annotations

from datetime import UTC, datetime, timedelta
from hashlib import sha256
from secrets import token_urlsafe
from uuid import UUID

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerifyMismatchError

from app.core.config import Settings

_password_hasher = PasswordHasher()


def hash_password(password: str) -> str:
    return _password_hasher.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    try:
        return _password_hasher.verify(password_hash, password)
    except (InvalidHashError, VerifyMismatchError):
        return False


def issue_access_token(user_id: UUID, device_id: UUID, settings: Settings) -> str:
    issued_at = datetime.now(UTC)
    payload = {
        "sub": str(user_id),
        "device_id": str(device_id),
        "iss": settings.jwt_issuer,
        "aud": settings.jwt_audience,
        "iat": issued_at,
        "exp": issued_at + timedelta(minutes=settings.access_token_minutes),
    }
    return jwt.encode(payload, settings.jwt_private_key, algorithm="HS256")


def decode_access_token(token: str, settings: Settings) -> dict[str, object]:
    return jwt.decode(
        token,
        settings.jwt_private_key,
        algorithms=["HS256"],
        audience=settings.jwt_audience,
        issuer=settings.jwt_issuer,
    )


def new_refresh_token() -> str:
    return token_urlsafe(48)


def token_digest(token: str) -> str:
    return sha256(token.encode("utf-8")).hexdigest()
