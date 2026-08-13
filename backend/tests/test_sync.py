"""Integration tests for the offline sync journal.

Runs against the developer database through the least-privilege app role,
so PostgreSQL RLS is exercised exactly as in production.  Each test drives
``sync._process_operation`` directly: the journal semantics (idempotent
replay, conflict detection, rejection reasons) are the correctness-critical
part of the offline-first product.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

import pytest
from sqlalchemy import text

from app.api.dependencies import Principal
from app.api.routes import sync as sync_module
from app.api.schemas import SyncOperation
from app.db.session import system_transaction, user_transaction


async def _apply(principal: Principal, operation: dict) -> sync_module.OperationResult:
    async with user_transaction(principal.user_id) as session:
        return await sync_module._process_operation(
            session, principal, SyncOperation.model_validate(operation)
        )


def _plan_payload(exercise_id: uuid.UUID) -> dict:
    return {
        "name": "测试训练计划",
        "goal": {},
        "blocks": [
            {
                "purpose": "primary_strength",
                "slots": [
                    {
                        "exercise_id": str(exercise_id),
                        "prescription": {
                            "prescription_type": "rep_range",
                            "set_count": 3,
                            "rep_min": 4,
                            "rep_max": 6,
                            "target_load_kg": 100.0,
                        },
                    }
                ],
            }
        ],
    }


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
                "password_hash": "not-a-real-hash",
            },
        )


async def _create_plan(
    principal: Principal, exercise_id: uuid.UUID, plan_id: uuid.UUID | None = None
) -> uuid.UUID:
    """Apply a plan create operation and return the plan's entity id."""
    entity_id = plan_id or uuid.uuid4()
    result = await _apply(
        principal,
        {
            "operation_id": uuid.uuid4(),
            "entity_type": "plan",
            "entity_id": entity_id,
            "operation_type": "create",
            "base_revision": None,
            "payload": _plan_payload(exercise_id),
        },
    )
    assert result.result == "accepted", result.detail
    return entity_id


async def _start_workout(
    principal: Principal, plan_id: uuid.UUID, session_id: uuid.UUID | None = None
) -> uuid.UUID:
    """Apply a workout create operation and return the session's entity id."""
    entity_id = session_id or uuid.uuid4()
    result = await _apply(
        principal,
        {
            "operation_id": uuid.uuid4(),
            "entity_type": "workout_session",
            "entity_id": entity_id,
            "operation_type": "create",
            "base_revision": None,
            "payload": {
                "plan_id": str(plan_id),
                "timezone": "Asia/Shanghai",
                "started_at": datetime.now(UTC).isoformat(),
            },
        },
    )
    assert result.result == "accepted", result.detail
    return entity_id


async def _workout_item_id(principal: Principal, session_id: uuid.UUID) -> uuid.UUID:
    async with user_transaction(principal.user_id) as session:
        item_id = await session.scalar(
            text("SELECT id FROM workout_items WHERE workout_session_id = :session_id"),
            {"session_id": session_id},
        )
    assert item_id is not None, "workout create must have produced one workout item"
    return item_id


async def _set_log_create(
    principal: Principal,
    session_id: uuid.UUID,
    item_id: uuid.UUID,
    set_number: int = 1,
    load_kg: float = 100.0,
    reps: int = 5,
) -> sync_module.OperationResult:
    return await _apply(
        principal,
        {
            "operation_id": uuid.uuid4(),
            "entity_type": "set_log",
            "entity_id": uuid.uuid4(),
            "operation_type": "create",
            "base_revision": None,
            "payload": {
                "workout_session_id": str(session_id),
                "workout_item_id": str(item_id),
                "set_number": set_number,
                "set_type": "working",
                "status": "completed",
                "load_kg": load_kg,
                "reps": reps,
            },
        },
    )


async def _seed_account(user_id: uuid.UUID) -> None:
    async with system_transaction() as session:
        await session.execute(
            text(
                """
                INSERT INTO users (id, email, password_hash, is_active, is_owner)
                VALUES (:id, :email, :password_hash, true, false)
                """
            ),
            {"id": user_id, "email": f"{uuid.uuid4().hex}@example.com", "password_hash": "x"},
        )


@pytest.mark.usefixtures("seed_user")
async def test_set_log_create_is_accepted_and_replay_is_idempotent(
    principal: Principal, seeded_exercise_ids: list[uuid.UUID]
) -> None:
    plan_id = await _create_plan(principal, seeded_exercise_ids[0])
    session_id = await _start_workout(principal, plan_id)
    item_id = await _workout_item_id(principal, session_id)

    operation = {
        "operation_id": uuid.uuid4(),
        "entity_type": "set_log",
        "entity_id": uuid.uuid4(),
        "operation_type": "create",
        "base_revision": None,
        "payload": {
            "workout_session_id": str(session_id),
            "workout_item_id": str(item_id),
            "set_number": 1,
            "set_type": "working",
            "status": "completed",
            "load_kg": 100.0,
            "reps": 5,
        },
    }
    first = await _apply(principal, operation)
    assert first.result == "accepted", first.detail
    assert first.server_revision is not None

    # A crashed client retries the same operation: the journal must return
    # the original result instead of applying it twice.
    replay = await _apply(principal, operation)
    assert replay == first


@pytest.mark.usefixtures("seed_user")
async def test_set_log_create_replayed_with_different_contents_is_rejected(
    principal: Principal, seeded_exercise_ids: list[uuid.UUID]
) -> None:
    plan_id = await _create_plan(principal, seeded_exercise_ids[0])
    session_id = await _start_workout(principal, plan_id)
    item_id = await _workout_item_id(principal, session_id)

    operation = {
        "operation_id": uuid.uuid4(),
        "entity_type": "set_log",
        "entity_id": uuid.uuid4(),
        "operation_type": "create",
        "base_revision": None,
        "payload": {
            "workout_session_id": str(session_id),
            "workout_item_id": str(item_id),
            "set_number": 1,
            "load_kg": 80.0,
            "reps": 8,
        },
    }
    assert (await _apply(principal, operation)).result == "accepted"

    tampered = {**operation, "payload": {**operation["payload"], "load_kg": 999.0}}
    result = await _apply(principal, tampered)
    assert result.result == "rejected"
    assert result.detail.get("reason") == "operation_id_reused_with_different_contents"


@pytest.mark.usefixtures("seed_user")
async def test_duplicate_set_log_create_conflicts(
    principal: Principal, seeded_exercise_ids: list[uuid.UUID]
) -> None:
    plan_id = await _create_plan(principal, seeded_exercise_ids[0])
    session_id = await _start_workout(principal, plan_id)
    item_id = await _workout_item_id(principal, session_id)

    assert (await _set_log_create(principal, session_id, item_id)).result == "accepted"
    conflict = await _set_log_create(principal, session_id, item_id)
    assert conflict.result == "conflict"
    assert conflict.detail.get("reason") == "set_number_already_recorded"
    assert conflict.server_revision is not None


@pytest.mark.usefixtures("seed_user")
async def test_set_log_update_requires_matching_base_revision(
    principal: Principal, seeded_exercise_ids: list[uuid.UUID]
) -> None:
    plan_id = await _create_plan(principal, seeded_exercise_ids[0])
    session_id = await _start_workout(principal, plan_id)
    item_id = await _workout_item_id(principal, session_id)
    set_log_id = uuid.uuid4()
    created = await _apply(
        principal,
        {
            "operation_id": uuid.uuid4(),
            "entity_type": "set_log",
            "entity_id": set_log_id,
            "operation_type": "create",
            "base_revision": None,
            "payload": {
                "workout_session_id": str(session_id),
                "workout_item_id": str(item_id),
                "set_number": 1,
                "set_type": "working",
                "status": "completed",
                "load_kg": 100.0,
                "reps": 5,
            },
        },
    )
    assert created.result == "accepted"
    revision = created.server_revision
    assert revision is not None

    update_payload = {
        "workout_session_id": str(session_id),
        "workout_item_id": str(item_id),
        "set_number": 1,
        "load_kg": 102.5,
        "reps": 5,
    }

    stale = await _apply(
        principal,
        {
            "operation_id": uuid.uuid4(),
            "entity_type": "set_log",
            "entity_id": set_log_id,
            "operation_type": "update",
            "base_revision": revision + 1,
            "payload": update_payload,
        },
    )
    assert stale.result == "conflict"
    assert stale.detail.get("reason") == "stale_base_revision"

    accepted = await _apply(
        principal,
        {
            "operation_id": uuid.uuid4(),
            "entity_type": "set_log",
            "entity_id": set_log_id,
            "operation_type": "update",
            "base_revision": revision,
            "payload": update_payload,
        },
    )
    assert accepted.result == "accepted"
    assert accepted.server_revision == revision + 1


@pytest.mark.usefixtures("seed_user")
async def test_plan_update_conflicts_after_another_device_changed_the_plan(
    principal: Principal, seeded_exercise_ids: list[uuid.UUID]
) -> None:
    plan_id = await _create_plan(principal, seeded_exercise_ids[0])

    async with user_transaction(principal.user_id) as session:
        revision = await session.scalar(
            text(
                """
                SELECT pv.revision FROM plan_versions pv
                JOIN plans p ON p.id = pv.plan_id AND pv.version_no = p.current_version_no
                WHERE p.id = :plan_id
                """
            ),
            {"plan_id": plan_id},
        )
    assert revision is not None

    update = {
        "operation_id": uuid.uuid4(),
        "entity_type": "plan",
        "entity_id": plan_id,
        "operation_type": "update",
        "base_revision": int(revision),
        "payload": {"blocks": _plan_payload(seeded_exercise_ids[1])["blocks"]},
    }
    accepted = await _apply(principal, update)
    assert accepted.result == "accepted", accepted.detail
    assert accepted.server_revision is not None

    stale_again = await _apply(principal, {**update, "operation_id": uuid.uuid4()})
    assert stale_again.result == "conflict"
    assert stale_again.detail.get("reason") == "plan_changed_on_server"


@pytest.mark.usefixtures("seed_user")
async def test_plan_delete_then_replay_is_idempotent(
    principal: Principal, seeded_exercise_ids: list[uuid.UUID]
) -> None:
    plan_id = await _create_plan(principal, seeded_exercise_ids[0])

    delete = {
        "operation_id": uuid.uuid4(),
        "entity_type": "plan",
        "entity_id": plan_id,
        "operation_type": "delete",
        "base_revision": None,
        "payload": {},
    }
    assert (await _apply(principal, delete)).result == "accepted"
    assert (await _apply(principal, delete)).result == "accepted"

    async with user_transaction(principal.user_id) as session:
        deleted_at = await session.scalar(
            text("SELECT deleted_at FROM plans WHERE id = :plan_id"), {"plan_id": plan_id}
        )
    assert deleted_at is not None


@pytest.mark.usefixtures("seed_user")
async def test_workout_completion_is_idempotent_and_blocks_later_set_logs(
    principal: Principal, seeded_exercise_ids: list[uuid.UUID]
) -> None:
    plan_id = await _create_plan(principal, seeded_exercise_ids[0])
    session_id = await _start_workout(principal, plan_id)
    item_id = await _workout_item_id(principal, session_id)

    finish = {
        "operation_id": uuid.uuid4(),
        "entity_type": "workout_session",
        "entity_id": session_id,
        "operation_type": "update",
        "base_revision": None,
        "payload": {"status": "completed", "ended_at": datetime.now(UTC).isoformat()},
    }
    completed = await _apply(principal, finish)
    assert completed.result == "accepted", completed.detail
    assert completed.server_revision is not None
    assert (await _apply(principal, finish)) == completed

    late_set = await _set_log_create(principal, session_id, item_id)
    assert late_set.result == "conflict"
    assert late_set.detail.get("reason") == "workout_not_in_progress"


@pytest.mark.usefixtures("seed_user")
async def test_operation_id_from_another_device_is_rejected(
    principal: Principal, seeded_exercise_ids: list[uuid.UUID]
) -> None:
    plan_id = await _create_plan(principal, seeded_exercise_ids[0])
    session_id = await _start_workout(principal, plan_id)
    item_id = await _workout_item_id(principal, session_id)

    operation = {
        "operation_id": uuid.uuid4(),
        "entity_type": "set_log",
        "entity_id": uuid.uuid4(),
        "operation_type": "create",
        "base_revision": None,
        "payload": {
            "workout_session_id": str(session_id),
            "workout_item_id": str(item_id),
            "set_number": 1,
            "load_kg": 100.0,
            "reps": 5,
        },
    }
    assert (await _apply(principal, operation)).result == "accepted"

    # Same user, second device: the journal row belongs to device A, so the
    # same operation_id from device B is an ownership violation, not a replay.
    other_device = Principal(user_id=principal.user_id, device_id=uuid.uuid4())
    result = await _apply(other_device, operation)
    assert result.result == "rejected"
    assert result.detail.get("reason") == "operation_id_owned_by_another_device"


@pytest.mark.usefixtures("seed_user")
async def test_set_log_for_another_users_workout_looks_missing(
    principal: Principal, seeded_exercise_ids: list[uuid.UUID]
) -> None:
    """RLS makes probing another user's workout ids indistinguishable from absence."""

    owner = Principal(user_id=uuid.uuid4(), device_id=uuid.uuid4())
    await _seed_account(owner.user_id)
    plan_id = await _create_plan(owner, seeded_exercise_ids[0])
    session_id = await _start_workout(owner, plan_id)
    item_id = await _workout_item_id(owner, session_id)

    result = await _set_log_create(principal, session_id, item_id)
    assert result.result == "rejected"
    assert result.detail.get("reason") == "workout_item_not_found"
