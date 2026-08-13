from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from typing import Annotated
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import text

from app.api.dependencies import Principal, require_principal
from app.api.schemas import (
    AuthMeResponse,
    LoginRequest,
    RefreshRequest,
    RegisterRequest,
    RegistrationStatusResponse,
    SessionResponse,
)
from app.core.config import Settings, get_settings
from app.core.security import (
    hash_password,
    issue_access_token,
    new_refresh_token,
    token_digest,
    verify_password,
)
from app.db.session import system_transaction, user_transaction

router = APIRouter(prefix="/v1/auth", tags=["auth"])


def _invalid_credentials() -> HTTPException:
    return HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")


async def _issue_device_session(
    session,
    *,
    user_id,
    device_id,
    device_name,
    platform,
    settings: Settings,
) -> SessionResponse:
    """Upsert one device session and return a fresh token pair.

    Shared by login and registration so both entry points behave identically
    for a new device.
    """

    now = datetime.now(UTC)
    refresh_token = new_refresh_token()
    refresh_expires_at = now + timedelta(days=settings.refresh_token_days)
    offline_lease_expires_at = now + timedelta(days=settings.offline_lease_days)
    await session.execute(
        text(
            """
            INSERT INTO device_sessions (
                id, user_id, device_id, device_name, platform, refresh_token_hash,
                refresh_expires_at, offline_lease_expires_at, last_online_at, revoked_at
            ) VALUES (
                :id, :user_id, :device_id, :device_name, :platform, :refresh_token_hash,
                :refresh_expires_at, :offline_lease_expires_at, :last_online_at, NULL
            )
            ON CONFLICT (user_id, device_id) DO UPDATE SET
                device_name = EXCLUDED.device_name,
                platform = EXCLUDED.platform,
                refresh_token_hash = EXCLUDED.refresh_token_hash,
                refresh_expires_at = EXCLUDED.refresh_expires_at,
                offline_lease_expires_at = EXCLUDED.offline_lease_expires_at,
                last_online_at = EXCLUDED.last_online_at,
                revoked_at = NULL,
                updated_at = EXCLUDED.last_online_at
            """
        ),
        {
            "id": uuid4(),
            "user_id": user_id,
            "device_id": device_id,
            "device_name": device_name,
            "platform": platform,
            "refresh_token_hash": token_digest(refresh_token),
            "refresh_expires_at": refresh_expires_at,
            "offline_lease_expires_at": offline_lease_expires_at,
            "last_online_at": now,
        },
    )
    return SessionResponse(
        access_token=issue_access_token(user_id, device_id, settings),
        refresh_token=refresh_token,
        expires_in_seconds=settings.access_token_minutes * 60,
        offline_lease_expires_at=offline_lease_expires_at,
    )


@router.post("/login", response_model=SessionResponse)
async def login(request: LoginRequest) -> SessionResponse:
    settings = get_settings()

    async with system_transaction() as session:
        result = await session.execute(
            text(
                """
                SELECT id, password_hash
                FROM users
                WHERE email = :email AND is_active = true AND deleted_at IS NULL
                """
            ),
            {"email": request.email},
        )
        user = result.mappings().one_or_none()
        if user is None or not verify_password(request.password, str(user["password_hash"])):
            raise _invalid_credentials()

    user_id = user["id"]
    async with user_transaction(user_id) as session:
        return await _issue_device_session(
            session,
            user_id=user_id,
            device_id=request.device_id,
            device_name=request.device_name,
            platform=request.platform,
            settings=settings,
        )


@router.post("/refresh", response_model=SessionResponse)
async def refresh(request: RefreshRequest) -> SessionResponse:
    settings = get_settings()
    now = datetime.now(UTC)
    current_refresh_token_hash = token_digest(request.refresh_token)
    next_refresh_token = new_refresh_token()
    refresh_expires_at = now + timedelta(days=settings.refresh_token_days)
    offline_lease_expires_at = now + timedelta(days=settings.offline_lease_days)

    async with system_transaction() as session:
        result = await session.execute(
            text(
                """
                SELECT app.find_refresh_session(
                    :device_id,
                    :refresh_token_hash,
                    :now
                )
                """
            ),
            {
                "device_id": request.device_id,
                "refresh_token_hash": current_refresh_token_hash,
                "now": now,
            },
        )
        user_id = result.scalar_one_or_none()
        if user_id is None:
            raise _invalid_credentials()

    async with user_transaction(user_id) as session:
        result = await session.execute(
            text(
                """
                UPDATE device_sessions
                SET refresh_token_hash = :refresh_token_hash,
                    refresh_expires_at = :refresh_expires_at,
                    offline_lease_expires_at = :offline_lease_expires_at,
                    last_online_at = :last_online_at,
                    updated_at = :last_online_at
                WHERE user_id = :user_id
                  AND device_id = :device_id
                  AND refresh_token_hash = :current_refresh_token_hash
                  AND refresh_expires_at > :now
                  AND revoked_at IS NULL
                RETURNING id
                """
            ),
            {
                "user_id": user_id,
                "device_id": request.device_id,
                "refresh_token_hash": token_digest(next_refresh_token),
                "current_refresh_token_hash": current_refresh_token_hash,
                "refresh_expires_at": refresh_expires_at,
                "offline_lease_expires_at": offline_lease_expires_at,
                "last_online_at": now,
                "now": now,
            },
        )
        if result.scalar_one_or_none() is None:
            # A concurrent refresh may have consumed this token after the
            # security-definer lookup.  Do not issue a second session pair.
            raise _invalid_credentials()

    return SessionResponse(
        access_token=issue_access_token(user_id, request.device_id, settings),
        refresh_token=next_refresh_token,
        expires_in_seconds=settings.access_token_minutes * 60,
        offline_lease_expires_at=offline_lease_expires_at,
    )


@router.get("/registration-status", response_model=RegistrationStatusResponse)
async def registration_status() -> RegistrationStatusResponse:
    return RegistrationStatusResponse(enabled=get_settings().registration_enabled)


@router.post("/register", response_model=SessionResponse, status_code=status.HTTP_201_CREATED)
async def register(request: RegisterRequest) -> SessionResponse:
    """Create one regular account and sign the new device in immediately.

    The switch is off by default; the CLI remains the only way to create the
    first owner.  Registration never grants owner rights.
    """

    settings = get_settings()
    if not settings.registration_enabled:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Registration is not enabled on this server.",
        )

    user_id = uuid4()
    async with system_transaction() as session:
        email_taken = await session.scalar(
            text(
                """
                SELECT EXISTS (
                    SELECT 1 FROM users
                    WHERE email = :email AND deleted_at IS NULL
                )
                """
            ),
            {"email": request.email},
        )
        if email_taken is True:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="An account with this email already exists.",
            )
        await session.execute(
            text(
                """
                INSERT INTO users (id, email, password_hash, is_active, is_owner)
                VALUES (:id, :email, :password_hash, true, false)
                """
            ),
            {"id": user_id, "email": request.email, "password_hash": hash_password(request.password)},
        )
        await session.execute(
            text(
                "INSERT INTO profiles (user_id, display_name) VALUES (:user_id, :display_name)"
            ),
            {"user_id": user_id, "display_name": request.display_name.strip()},
        )
        await session.execute(
            text(
                """
                INSERT INTO audit_logs (id, actor_user_id, action, entity_type, entity_id, after_json)
                VALUES (:id, :actor_user_id, 'register', 'user', :entity_id, CAST(:after_json AS jsonb))
                """
            ),
            {
                "id": uuid4(),
                "actor_user_id": user_id,
                "entity_id": user_id,
                "after_json": json.dumps({"email": request.email, "display_name": request.display_name.strip()}),
            },
        )

    async with user_transaction(user_id) as session:
        return await _issue_device_session(
            session,
            user_id=user_id,
            device_id=request.device_id,
            device_name=request.device_name,
            platform=request.platform,
            settings=settings,
        )


@router.get("/me", response_model=AuthMeResponse)
async def auth_me(principal: Annotated[Principal, Depends(require_principal)]) -> AuthMeResponse:
    """Return the signed-in account; the client uses this to show owner UI."""

    async with system_transaction() as session:
        row = (
            await session.execute(
                text(
                    """
                    SELECT id, email, is_owner
                    FROM users
                    WHERE id = :user_id AND is_active = true AND deleted_at IS NULL
                    """
                ),
                {"user_id": principal.user_id},
            )
        ).mappings().one_or_none()
    if row is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Account is no longer active")
    return AuthMeResponse(user_id=row["id"], email=str(row["email"]), is_owner=bool(row["is_owner"]))
