from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated
from uuid import UUID

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import text

from app.core.config import Settings, get_settings
from app.core.security import decode_access_token
from app.db.session import system_transaction

_bearer = HTTPBearer(auto_error=False)


@dataclass(frozen=True)
class Principal:
    user_id: UUID
    device_id: UUID


def require_principal(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> Principal:
    if credentials is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")

    try:
        claims = decode_access_token(credentials.credentials, settings)
        return Principal(user_id=UUID(str(claims["sub"])), device_id=UUID(str(claims["device_id"])))
    except (KeyError, ValueError, jwt.PyJWTError) as error:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid bearer token") from error


async def require_owner(
    principal: Annotated[Principal, Depends(require_principal)],
) -> Principal:
    async with system_transaction() as session:
        is_owner = await session.scalar(
            text("SELECT is_owner FROM users WHERE id = :user_id AND is_active = true AND deleted_at IS NULL"),
            {"user_id": principal.user_id},
        )
    if is_owner is not True:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Owner permission required")
    return principal
