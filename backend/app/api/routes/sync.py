from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import ValidationError
from sqlalchemy import text

from app.api.dependencies import Principal, require_principal
from app.api.routes.plans import _create_draft_version, _insert_version_content
from app.api.routes.workouts import _start_session
from app.api.schemas import (
    CreatePlanRequest,
    OperationResult,
    PlanStageBlockInput,
    SyncOperation,
    SyncPullChange,
    SyncPullResponse,
    SyncPushRequest,
    SyncPushResponse,
    SyncSetLogPayload,
)
from app.db.session import user_transaction

router = APIRouter(prefix="/v1/sync", tags=["sync"])


def _json(value: object) -> str:
    """Produce a stable JSON value for jsonb parameters and replay comparisons."""

    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), default=str)


def _result_payload(result: OperationResult) -> str:
    return _json(
        {
            "server_revision": result.server_revision,
            "detail": result.detail,
        }
    )


def _journal_result(operation_id: UUID, row: dict[str, object]) -> OperationResult:
    payload = row.get("result_payload")
    if not isinstance(payload, dict):
        payload = {}
    detail = payload.get("detail")
    server_revision = payload.get("server_revision")
    return OperationResult(
        operation_id=operation_id,
        result=str(row["result"]),
        server_revision=int(server_revision) if server_revision is not None else None,
        detail=detail if isinstance(detail, dict) else {},
    )


def _rejected(operation_id: UUID, reason: str, **detail: object) -> OperationResult:
    return OperationResult(
        operation_id=operation_id,
        result="rejected",
        detail={"reason": reason, **detail},
    )


def _conflict(
    operation_id: UUID,
    reason: str,
    server_revision: int | None = None,
    **detail: object,
) -> OperationResult:
    return OperationResult(
        operation_id=operation_id,
        result="conflict",
        server_revision=server_revision,
        detail={"reason": reason, **detail},
    )


async def _find_existing_operation(session, operation: SyncOperation) -> dict[str, object] | None:
    result = await session.execute(
        text(
            """
            SELECT operation_id, device_id, entity_type, entity_id, operation_type,
                   base_revision, payload, result, result_payload, server_cursor
            FROM sync_operations
            WHERE operation_id = :operation_id
            """
        ),
        {"operation_id": operation.operation_id},
    )
    return result.mappings().one_or_none()


def _same_operation(operation: SyncOperation, existing: dict[str, object]) -> bool:
    return (
        str(existing["entity_type"]) == operation.entity_type
        and existing["entity_id"] == operation.entity_id
        and str(existing["operation_type"]) == operation.operation_type
        and existing["base_revision"] == operation.base_revision
        and _json(existing["payload"]) == _json(operation.payload)
    )


async def _claim_operation(session, principal: Principal, operation: SyncOperation) -> int | None:
    """Reserve an immutable journal row before applying a business mutation.

    The reservation and the mutation share the caller's transaction.  A crash
    or unexpected database error therefore rolls both back; an operation is
    never acknowledged merely because it reached the journal.
    """

    row = (
        await session.execute(
            text(
                """
                INSERT INTO sync_operations (
                    operation_id, user_id, device_id, entity_type, entity_id,
                    operation_type, base_revision, payload, result, result_payload
                ) VALUES (
                    :operation_id, :user_id, :device_id, :entity_type, :entity_id,
                    :operation_type, :base_revision, CAST(:payload AS jsonb), 'rejected',
                    CAST(:result_payload AS jsonb)
                )
                ON CONFLICT (operation_id) DO NOTHING
                RETURNING server_cursor
                """
            ),
            {
                "operation_id": operation.operation_id,
                "user_id": principal.user_id,
                "device_id": principal.device_id,
                "entity_type": operation.entity_type,
                "entity_id": operation.entity_id,
                "operation_type": operation.operation_type,
                "base_revision": operation.base_revision,
                "payload": _json(operation.payload),
                "result_payload": _json({"detail": {"reason": "processing"}}),
            },
        )
    ).mappings().one_or_none()
    return int(row["server_cursor"]) if row is not None else None


async def _finish_journal(session, operation: SyncOperation, result: OperationResult) -> None:
    await session.execute(
        text(
            """
            UPDATE sync_operations
            SET result = :result,
                result_payload = CAST(:result_payload AS jsonb)
            WHERE operation_id = :operation_id
            """
        ),
        {
            "operation_id": operation.operation_id,
            "result": result.result,
            "result_payload": _result_payload(result),
        },
    )


def _set_log_values(payload: SyncSetLogPayload) -> dict[str, object]:
    values = payload.model_dump(
        exclude={"workout_session_id", "workout_item_id", "set_number"},
    )
    values["performed_at"] = values["performed_at"] or datetime.now(UTC)
    return values


async def _set_log_target(session, payload: SyncSetLogPayload) -> dict[str, object] | None:
    result = await session.execute(
        text(
            """
            SELECT wi.id AS workout_item_id, ws.id AS workout_session_id,
                   ws.status AS workout_status, ws.revision AS session_revision
            FROM workout_items AS wi
            JOIN workout_sessions AS ws ON ws.id = wi.workout_session_id
            WHERE wi.id = :workout_item_id
              AND ws.id = :workout_session_id
              AND ws.deleted_at IS NULL
            FOR UPDATE OF ws
            """
        ),
        {
            "workout_item_id": payload.workout_item_id,
            "workout_session_id": payload.workout_session_id,
        },
    )
    return result.mappings().one_or_none()


async def _apply_set_log(
    session,
    operation: SyncOperation,
) -> OperationResult:
    if operation.operation_type == "delete":
        return _rejected(operation.operation_id, "set_log_delete_not_supported")
    if operation.operation_type not in {"create", "update"}:
        return _rejected(operation.operation_id, "unsupported_set_log_operation_type")

    try:
        payload = SyncSetLogPayload.model_validate(operation.payload)
    except ValidationError as error:
        return _rejected(
            operation.operation_id,
            "invalid_set_log_payload",
            validation_errors=[
                {"path": ".".join(str(part) for part in item["loc"]), "type": item["type"]}
                for item in error.errors()
            ],
        )

    if operation.operation_type == "create" and operation.base_revision is not None:
        return _rejected(operation.operation_id, "create_must_not_have_base_revision")
    if operation.operation_type == "update" and operation.base_revision is None:
        return _rejected(operation.operation_id, "update_requires_base_revision")

    target = await _set_log_target(session, payload)
    if target is None:
        # RLS intentionally makes an inaccessible target indistinguishable from
        # a missing one, so a device cannot probe another user's workout IDs.
        return _rejected(operation.operation_id, "workout_item_not_found")
    if target["workout_status"] != "in_progress":
        return _conflict(
            operation.operation_id,
            "workout_not_in_progress",
            session_status=str(target["workout_status"]),
            session_revision=int(target["session_revision"]),
        )

    values = _set_log_values(payload)
    params = {
        "set_log_id": operation.entity_id,
        "workout_item_id": payload.workout_item_id,
        "set_number": payload.set_number,
        **values,
    }

    if operation.operation_type == "create":
        created = (
            await session.execute(
                text(
                    """
                    INSERT INTO set_logs (
                        id, workout_item_id, set_number, set_type, status, load_kg, original_load,
                        original_unit, is_per_side, includes_bar, reps, duration_seconds, distance_meters,
                        rpe, rir, pain_score, technique_ok, notes, performed_at
                    ) VALUES (
                        :set_log_id, :workout_item_id, :set_number, :set_type, :status, :load_kg,
                        :original_load, :original_unit, :is_per_side, :includes_bar, :reps,
                        :duration_seconds, :distance_meters, :rpe, :rir, :pain_score, :technique_ok,
                        :notes, :performed_at
                    ) ON CONFLICT DO NOTHING
                    RETURNING revision
                    """
                ),
                params,
            )
        ).mappings().one_or_none()
        if created is not None:
            return OperationResult(
                operation_id=operation.operation_id,
                result="accepted",
                server_revision=int(created["revision"]),
            )

        existing = (
            await session.execute(
                text(
                    """
                    SELECT id, revision
                    FROM set_logs
                    WHERE workout_item_id = :workout_item_id AND set_number = :set_number
                    """
                ),
                params,
            )
        ).mappings().one_or_none()
        if existing is not None:
            return _conflict(
                operation.operation_id,
                "set_number_already_recorded",
                server_revision=int(existing["revision"]),
                current_set_log_id=str(existing["id"]),
            )
        return _conflict(operation.operation_id, "set_log_id_already_exists")

    updated = (
        await session.execute(
            text(
                """
                UPDATE set_logs
                SET set_type = :set_type,
                    status = :status,
                    load_kg = :load_kg,
                    original_load = :original_load,
                    original_unit = :original_unit,
                    is_per_side = :is_per_side,
                    includes_bar = :includes_bar,
                    reps = :reps,
                    duration_seconds = :duration_seconds,
                    distance_meters = :distance_meters,
                    rpe = :rpe,
                    rir = :rir,
                    pain_score = :pain_score,
                    technique_ok = :technique_ok,
                    notes = :notes,
                    performed_at = :performed_at,
                    updated_at = now(),
                    revision = revision + 1
                WHERE id = :set_log_id
                  AND workout_item_id = :workout_item_id
                  AND set_number = :set_number
                  AND revision = :base_revision
                RETURNING revision
                """
            ),
            {"base_revision": operation.base_revision, **params},
        )
    ).mappings().one_or_none()
    if updated is not None:
        return OperationResult(
            operation_id=operation.operation_id,
            result="accepted",
            server_revision=int(updated["revision"]),
        )

    existing = (
        await session.execute(
            text(
                """
                SELECT id, workout_item_id, set_number, revision
                FROM set_logs
                WHERE id = :set_log_id
                """
            ),
            params,
        )
    ).mappings().one_or_none()
    if existing is None:
        return _conflict(operation.operation_id, "set_log_missing")
    if existing["workout_item_id"] != payload.workout_item_id or existing["set_number"] != payload.set_number:
        return _rejected(operation.operation_id, "set_log_target_mismatch")
    return _conflict(
        operation.operation_id,
        "stale_base_revision",
        server_revision=int(existing["revision"]),
    )


def _validation_errors(error: ValidationError) -> list[dict[str, str]]:
    return [
        {"path": ".".join(str(part) for part in item["loc"]), "type": item["type"]}
        for item in error.errors()
    ]


async def _apply_plan_create(session, principal: Principal, operation: SyncOperation) -> OperationResult:
    """Create one plan from an offline canvas and publish it immediately.

    Mirrors the online create-then-publish flow in one journal operation so a
    phone can build a plan in the gym and publish it when connectivity returns.
    """

    try:
        request = CreatePlanRequest.model_validate(operation.payload)
    except ValidationError as error:
        return _rejected(operation.operation_id, "invalid_plan_payload", validation_errors=_validation_errors(error))

    plan_version_id = uuid4()
    try:
        await session.execute(
            text(
                """
                INSERT INTO plans (id, user_id, name, goal_json, current_version_no, status)
                VALUES (:id, :user_id, :name, CAST(:goal_json AS jsonb), 1, 'active')
                """
            ),
            {
                "id": operation.entity_id,
                "user_id": principal.user_id,
                "name": request.name,
                "goal_json": json.dumps(request.goal, ensure_ascii=False),
            },
        )
        await session.execute(
            text(
                """
                INSERT INTO plan_versions (id, plan_id, version_no, is_published, published_at)
                VALUES (:id, :plan_id, 1, true, now())
                """
            ),
            {"id": plan_version_id, "plan_id": operation.entity_id},
        )
        await _insert_version_content(session, plan_version_id, request.name, request.blocks)
    except HTTPException as error:
        return _rejected(operation.operation_id, "invalid_plan_blocks", detail=str(error.detail))

    return OperationResult(operation_id=operation.operation_id, result="accepted")


async def _apply_plan_update(session, operation: SyncOperation) -> OperationResult:
    """Replace a published plan through the draft-clone-publish path.

    ``operation.base_revision`` is the revision of the plan's current version
    the offline device based its edit on; a newer revision means another
    device changed the plan and the edit must be reviewed manually.
    """

    if operation.base_revision is None:
        return _rejected(operation.operation_id, "update_requires_base_revision")
    raw_blocks = operation.payload.get("blocks")
    if not isinstance(raw_blocks, list):
        return _rejected(operation.operation_id, "invalid_plan_payload")
    try:
        blocks = [PlanStageBlockInput.model_validate(item) for item in raw_blocks]
    except ValidationError as error:
        return _rejected(operation.operation_id, "invalid_plan_blocks", validation_errors=_validation_errors(error))

    current = (
        await session.execute(
            text(
                """
                SELECT p.name, p.current_version_no, pv.revision
                FROM plans AS p
                JOIN plan_versions AS pv
                  ON pv.plan_id = p.id AND pv.version_no = p.current_version_no
                WHERE p.id = :plan_id AND p.deleted_at IS NULL
                FOR UPDATE OF p, pv
                """
            ),
            {"plan_id": operation.entity_id},
        )
    ).mappings().one_or_none()
    if current is None:
        return _rejected(operation.operation_id, "plan_not_found")
    current_revision = int(current["revision"])
    if current_revision != operation.base_revision:
        return _conflict(
            operation.operation_id,
            "plan_changed_on_server",
            server_revision=current_revision,
        )

    try:
        draft = await _create_draft_version(session, operation.entity_id)
    except HTTPException as error:
        return _conflict(
            operation.operation_id,
            "plan_draft_unavailable",
            server_revision=current_revision,
            detail=str(error.detail),
        )

    await session.execute(
        text("DELETE FROM session_templates WHERE plan_version_id = :plan_version_id"),
        {"plan_version_id": draft["id"]},
    )
    await _insert_version_content(session, draft["id"], str(current["name"]), blocks)
    new_revision = int(
        await session.scalar(
            text(
                """
                UPDATE plan_versions
                SET is_published = true, published_at = now(), updated_at = now(), revision = revision + 1
                WHERE id = :plan_version_id
                RETURNING revision
                """
            ),
            {"plan_version_id": draft["id"]},
        )
    )
    await session.execute(
        text(
            """
            UPDATE plans
            SET current_version_no = :version_no, updated_at = now(), revision = revision + 1
            WHERE id = :plan_id
            """
        ),
        {"plan_id": operation.entity_id, "version_no": draft["version_no"]},
    )
    return OperationResult(operation_id=operation.operation_id, result="accepted", server_revision=new_revision)


async def _apply_plan_delete(session, operation: SyncOperation) -> OperationResult:
    """Soft-delete one plan; history keeps its immutable workout snapshots."""

    row = (
        await session.execute(
            text(
                """
                UPDATE plans
                SET deleted_at = now(), updated_at = now()
                WHERE id = :plan_id AND deleted_at IS NULL
                RETURNING id
                """
            ),
            {"plan_id": operation.entity_id},
        )
    ).mappings().one_or_none()
    if row is None:
        return _conflict(operation.operation_id, "plan_not_found")
    return OperationResult(operation_id=operation.operation_id, result="accepted")


async def _apply_workout_session_create(session, principal: Principal, operation: SyncOperation) -> OperationResult:
    """Create one resumable workout from a published plan while offline."""

    payload = operation.payload
    try:
        plan_id = UUID(str(payload.get("plan_id")))
        timezone = str(payload.get("timezone") or "Asia/Shanghai")
        started_at = (
            datetime.fromisoformat(str(payload["started_at"]))
            if payload.get("started_at")
            else datetime.now(UTC)
        )
    except (KeyError, TypeError, ValueError):
        return _rejected(operation.operation_id, "invalid_workout_payload")

    try:
        await _start_session(
            session,
            user_id=principal.user_id,
            plan_id=plan_id,
            workout_session_id=operation.entity_id,
            started_at=started_at,
            timezone=timezone,
            active_device_id=principal.device_id,
        )
    except HTTPException as error:
        if error.status_code == status.HTTP_409_CONFLICT:
            return _conflict(operation.operation_id, str(error.detail))
        return _rejected(operation.operation_id, "workout_start_failed", detail=str(error.detail))

    return OperationResult(operation_id=operation.operation_id, result="accepted")


async def _apply_workout_session_update(session, operation: SyncOperation) -> OperationResult:
    """Finish or abandon an in-progress workout from the offline queue."""

    payload = operation.payload
    status_value = payload.get("status")
    if status_value not in {"completed", "abandoned"}:
        return _rejected(operation.operation_id, "invalid_workout_status")
    try:
        ended_at = (
            datetime.fromisoformat(str(payload["ended_at"]))
            if payload.get("ended_at")
            else datetime.now(UTC)
        )
    except (KeyError, TypeError, ValueError):
        return _rejected(operation.operation_id, "invalid_ended_at")

    row = (
        await session.execute(
            text(
                """
                UPDATE workout_sessions
                SET status = :status, ended_at = :ended_at, updated_at = now(), revision = revision + 1
                WHERE id = :workout_session_id AND status = 'in_progress' AND deleted_at IS NULL
                RETURNING id, revision
                """
            ),
            {
                "workout_session_id": operation.entity_id,
                "status": status_value,
                "ended_at": ended_at,
            },
        )
    ).mappings().one_or_none()
    if row is None:
        return _conflict(operation.operation_id, "workout_not_in_progress")
    return OperationResult(operation_id=operation.operation_id, result="accepted", server_revision=int(row["revision"]))


async def _apply_operation(session, principal: Principal, operation: SyncOperation) -> OperationResult:
    if operation.entity_type == "set_log":
        return await _apply_set_log(session, operation)
    if operation.entity_type == "plan":
        if operation.operation_type == "create":
            return await _apply_plan_create(session, principal, operation)
        if operation.operation_type == "update":
            return await _apply_plan_update(session, operation)
        if operation.operation_type == "delete":
            return await _apply_plan_delete(session, operation)
        return _rejected(operation.operation_id, "plan_operation_not_supported")
    if operation.entity_type == "workout_session":
        if operation.operation_type == "create":
            return await _apply_workout_session_create(session, principal, operation)
        if operation.operation_type == "update":
            return await _apply_workout_session_update(session, operation)
        return _rejected(operation.operation_id, "workout_session_delete_not_supported")
    return _rejected(operation.operation_id, "unsupported_entity_type")


async def _process_operation(session, principal: Principal, operation: SyncOperation) -> OperationResult:
    existing = await _find_existing_operation(session, operation)
    if existing is not None:
        if existing["device_id"] != principal.device_id:
            return _rejected(operation.operation_id, "operation_id_owned_by_another_device")
        if not _same_operation(operation, existing):
            return _rejected(operation.operation_id, "operation_id_reused_with_different_contents")
        return _journal_result(operation.operation_id, existing)

    claimed_cursor = await _claim_operation(session, principal, operation)
    if claimed_cursor is None:
        # A UUID collision from a different user is deliberately not exposed;
        # an identical retry from this user is handled by the branch above.
        existing = await _find_existing_operation(session, operation)
        if existing is not None:
            if existing["device_id"] != principal.device_id:
                return _rejected(operation.operation_id, "operation_id_owned_by_another_device")
            if not _same_operation(operation, existing):
                return _rejected(operation.operation_id, "operation_id_reused_with_different_contents")
            return _journal_result(operation.operation_id, existing)
        return _rejected(operation.operation_id, "operation_id_already_in_use")

    result = await _apply_operation(session, principal, operation)
    await _finish_journal(session, operation, result)
    return result


@router.post("/push", response_model=SyncPushResponse)
async def push_operations(
    request: SyncPushRequest,
    principal: Annotated[Principal, Depends(require_principal)],
) -> SyncPushResponse:
    if request.device_id != principal.device_id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="The request device_id must match the access token.",
        )

    async with user_transaction(principal.user_id) as session:
        results = [await _process_operation(session, principal, operation) for operation in request.operations]
        next_cursor = int(
            await session.scalar(text("SELECT COALESCE(max(server_cursor), 0) FROM sync_operations")) or 0
        )
    return SyncPushResponse(results=results, next_cursor=next_cursor)


@router.get("/pull", response_model=SyncPullResponse)
async def pull_operations(
    principal: Annotated[Principal, Depends(require_principal)],
    cursor: int = Query(default=0, ge=0),
    limit: int = Query(default=200, ge=1, le=500),
) -> SyncPullResponse:
    async with user_transaction(principal.user_id) as session:
        rows = list(
            (
                await session.execute(
                    text(
                        """
                        SELECT server_cursor, operation_id, device_id, entity_type, entity_id,
                               operation_type, base_revision, payload, result, result_payload, created_at
                        FROM sync_operations
                        WHERE server_cursor > :cursor
                        ORDER BY server_cursor ASC
                        LIMIT :limit_plus_one
                        """
                    ),
                    {"cursor": cursor, "limit_plus_one": limit + 1},
                )
            ).mappings()
        )

    has_more = len(rows) > limit
    page = rows[:limit]
    changes = [
        SyncPullChange(
            server_cursor=int(row["server_cursor"]),
            operation_id=row["operation_id"],
            device_id=row["device_id"],
            entity_type=str(row["entity_type"]),
            entity_id=row["entity_id"],
            operation_type=str(row["operation_type"]),
            base_revision=int(row["base_revision"]) if row["base_revision"] is not None else None,
            payload=row["payload"],
            result=str(row["result"]),
            server_revision=(
                int(row["result_payload"].get("server_revision"))
                if isinstance(row["result_payload"], dict)
                and row["result_payload"].get("server_revision") is not None
                else None
            ),
            detail=(
                row["result_payload"].get("detail", {})
                if isinstance(row["result_payload"], dict)
                else {}
            ),
            created_at=row["created_at"],
        )
        for row in page
    ]
    return SyncPullResponse(
        changes=changes,
        next_cursor=changes[-1].server_cursor if changes else cursor,
        has_more=has_more,
    )
