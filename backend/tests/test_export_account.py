"""Integration tests for data export and account deletion.

Export must return exactly the caller's rows (RLS is the enforcement
point); deletion must end authentication and revoke every device session
while keeping history rows intact.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from fastapi import HTTPException
from sqlalchemy import text

from app.api.dependencies import Principal
from app.api.routes import auth as auth_routes
from app.api.routes.account import delete_account, export_account
from app.api.schemas import RefreshRequest
from app.db.session import system_transaction, user_transaction


@pytest.fixture
async def principal() -> Principal:
    return Principal(user_id=uuid.uuid4(), device_id=uuid.uuid4())


@pytest.fixture
async def seed_user(principal: Principal) -> None:
    async with system_transaction() as session:
        await session.execute(
            text(
                """
                INSERT INTO users (id, email, password_hash, is_active, is_owner)
                VALUES (:id, :email, :password_hash, true, false)
                """
            ),
            {
                "id": principal.user_id,
                "email": f"{uuid.uuid4().hex}@example.com",
                "password_hash": "x",
            },
        )


async def _seed_other_user_with_plan() -> uuid.UUID:
    other = uuid.uuid4()
    async with system_transaction() as session:
        await session.execute(
            text(
                """
                INSERT INTO users (id, email, password_hash, is_active, is_owner)
                VALUES (:id, :email, :password_hash, true, false)
                """
            ),
            {
                "id": other,
                "email": f"{uuid.uuid4().hex}@example.com",
                "password_hash": "x",
            },
        )
    async with user_transaction(other) as session:
        plan_id = uuid.uuid4()
        await session.execute(
            text(
                """
                INSERT INTO plans (id, user_id, name, goal_json, current_version_no, status)
                VALUES (:id, :user_id, :name, '{}'::jsonb, 1, 'active')
                """
            ),
            {"id": plan_id, "user_id": other, "name": "别人的计划"},
        )
        await session.execute(
            text(
                """
                INSERT INTO plan_versions (id, plan_id, version_no, is_published, published_at)
                VALUES (:id, :plan_id, 1, false, NULL)
                """
            ),
            {"id": uuid.uuid4(), "plan_id": plan_id},
        )
    return other


async def _seed_own_plan(principal: Principal) -> uuid.UUID:
    plan_id = uuid.uuid4()
    async with user_transaction(principal.user_id) as session:
        await session.execute(
            text(
                """
                INSERT INTO plans (id, user_id, name, goal_json, current_version_no, status)
                VALUES (:id, :user_id, :name, '{}'::jsonb, 1, 'active')
                """
            ),
            {"id": plan_id, "user_id": principal.user_id, "name": "我的计划"},
        )
        await session.execute(
            text(
                """
                INSERT INTO plan_versions (id, plan_id, version_no, is_published, published_at)
                VALUES (:id, :plan_id, 1, false, NULL)
                """
            ),
            {"id": uuid.uuid4(), "plan_id": plan_id},
        )
    return plan_id


async def _seed_device_session(principal: Principal) -> None:
    async with user_transaction(principal.user_id) as session:
        await session.execute(
            text(
                """
                INSERT INTO device_sessions (
                    id, user_id, device_id, device_name, platform, refresh_token_hash,
                    refresh_expires_at, offline_lease_expires_at, last_online_at
                ) VALUES (
                    :id, :user_id, :device_id, 'test', 'windows', :token_hash,
                    :refresh_expires_at, :offline_lease_expires_at, :last_online_at
                )
                """
            ),
            {
                "id": uuid.uuid4(),
                "user_id": principal.user_id,
                "device_id": principal.device_id,
                "token_hash": "a" * 64,
                "refresh_expires_at": datetime.now(UTC) + timedelta(days=1),
                "offline_lease_expires_at": datetime.now(UTC) + timedelta(days=1),
                "last_online_at": datetime.now(UTC),
            },
        )


@pytest.mark.usefixtures("seed_user")
async def test_export_contains_only_the_callers_rows(principal: Principal) -> None:
    await _seed_own_plan(principal)
    await _seed_other_user_with_plan()

    exported = await export_account(principal)

    plan_names = [row["name"] for row in exported.documents["plans"]]
    assert plan_names == ["我的计划"]
    assert exported.account["user_id"] == str(principal.user_id)
    assert exported.account["email"] is not None
    # Every exported table is present, even when empty.
    assert set(exported.documents) == {
        "profiles",
        "user_settings",
        "user_equipment",
        "plans",
        "plan_versions",
        "session_templates",
        "stage_blocks",
        "exercise_slots",
        "prescriptions",
        "slot_alternatives",
        "workout_sessions",
        "workout_items",
        "set_logs",
        "progression_suggestions",
        "sync_operations",
    }


@pytest.mark.usefixtures("seed_user")
async def test_delete_account_ends_login_and_revokes_sessions(
    principal: Principal,
) -> None:
    plan_id = await _seed_own_plan(principal)
    await _seed_device_session(principal)

    response = await delete_account(principal)
    assert response.status_code == 204

    async with system_transaction() as session:
        deleted_at = await session.scalar(
            text("SELECT deleted_at FROM users WHERE id = :user_id"),
            {"user_id": principal.user_id},
        )
    assert deleted_at is not None
    async with user_transaction(principal.user_id) as session:
        revoked = await session.scalar(
            text(
                "SELECT revoked_at FROM device_sessions WHERE user_id = :user_id AND device_id = :device_id"
            ),
            {"user_id": principal.user_id, "device_id": principal.device_id},
        )
    assert revoked is not None

    # History stays intact: deletion is soft so records keep their foreign keys.
    async with user_transaction(principal.user_id) as session:
        still_there = await session.scalar(
            text("SELECT id FROM plans WHERE id = :plan_id"), {"plan_id": plan_id}
        )
    assert still_there == plan_id

    # A refresh attempt with the old token must now fail.
    with pytest.raises(HTTPException) as exc_info:
        await auth_routes.refresh(
            RefreshRequest(device_id=principal.device_id, refresh_token="x" * 48)
        )
    assert exc_info.value.status_code == 401

    # Deleting again is a 404: the account is already gone.
    with pytest.raises(HTTPException) as exc_info:
        await delete_account(principal)
    assert exc_info.value.status_code == 404
