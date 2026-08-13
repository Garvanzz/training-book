from uuid import uuid4

import jwt
import pytest
from pydantic import ValidationError

from app.core.config import Settings
from app.core.security import (
    hash_password,
    issue_access_token,
    token_digest,
    verify_password,
)


def test_password_round_trip() -> None:
    password_hash = hash_password("not-a-real-production-password")

    assert verify_password("not-a-real-production-password", password_hash)
    assert not verify_password("wrong-password", password_hash)


def test_access_token_has_expected_subject_and_device() -> None:
    user_id = uuid4()
    device_id = uuid4()
    settings = Settings(
        database_url="postgresql+asyncpg://example",
        jwt_private_key="test-secret-that-is-at-least-32-bytes",
    )

    token = issue_access_token(user_id, device_id, settings)
    claims = jwt.decode(
        token,
        settings.jwt_private_key,
        algorithms=["HS256"],
        audience=settings.jwt_audience,
        issuer=settings.jwt_issuer,
    )

    assert claims["sub"] == str(user_id)
    assert claims["device_id"] == str(device_id)
    assert token_digest(token) != token


def test_hmac_secret_must_have_at_least_256_bits() -> None:
    with pytest.raises(ValidationError):
        Settings(database_url="postgresql+asyncpg://example", jwt_private_key="too-short")
