from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import text

from app.api.dependencies import Principal, require_principal
from app.api.schemas import (
    ActiveWorkoutResponse,
    CompleteWorkoutResponse,
    SetLogInput,
    SetLogResponse,
    StartWorkoutRequest,
    WorkoutHistoryEntryResponse,
    WorkoutHistoryPageResponse,
    WorkoutItemResponse,
    WorkoutSessionResponse,
)
from app.db.session import user_transaction

router = APIRouter(prefix="/v1/workouts", tags=["workouts"])


def _as_number(value: object) -> float | None:
    return float(value) if value is not None else None


async def _session_items(session, workout_session_id: UUID) -> list[WorkoutItemResponse]:
    result = await session.execute(
        text(
            """
            SELECT id, source_slot_id, exercise_id, exercise_version_no,
                   exercise_snapshot, prescription_snapshot, sort_order
            FROM workout_items
            WHERE workout_session_id = :workout_session_id
            ORDER BY sort_order
            """
        ),
        {"workout_session_id": workout_session_id},
    )
    items = [WorkoutItemResponse.model_validate(row) for row in result.mappings()]
    if not items:
        return items

    logs = await session.execute(
        text(
            """
            SELECT id, workout_item_id, set_number, set_type, status, load_kg,
                   original_load, original_unit, is_per_side, includes_bar,
                   reps, duration_seconds, distance_meters, rpe, rir,
                   pain_score, technique_ok, notes, performed_at
            FROM set_logs
            WHERE workout_item_id IN (
                SELECT id FROM workout_items WHERE workout_session_id = :workout_session_id
            )
            ORDER BY workout_item_id, set_number
            """
        ),
        {"workout_session_id": workout_session_id},
    )
    logs_by_item: dict[UUID, list[SetLogResponse]] = {}
    for mapped_row in logs.mappings():
        row = dict(mapped_row)
        item_id = row.pop("workout_item_id")
        logs_by_item.setdefault(item_id, []).append(SetLogResponse.model_validate(row))
    return [item.model_copy(update={"set_logs": logs_by_item.get(item.id, [])}) for item in items]


async def _workout_response(session, workout_session_id: UUID) -> WorkoutSessionResponse | None:
    """Fetch one user-scoped workout with its immutable item and log detail."""

    workout = (
        await session.execute(
            text(
                """
                SELECT ws.id, pv.plan_id AS source_plan_id,
                       ws.session_snapshot ->> 'plan_name' AS plan_name,
                       COALESCE(
                           (ws.session_snapshot ->> 'plan_version_no')::integer,
                           pv.version_no
                       ) AS source_plan_version_no,
                       ws.status, ws.started_at, ws.ended_at, ws.timezone
                FROM workout_sessions AS ws
                LEFT JOIN plan_versions AS pv ON pv.id = ws.source_plan_version_id
                WHERE ws.id = :workout_session_id
                  AND ws.deleted_at IS NULL
                """
            ),
            {"workout_session_id": workout_session_id},
        )
    ).mappings().one_or_none()
    if workout is None:
        return None
    return WorkoutSessionResponse(items=await _session_items(session, workout_session_id), **workout)


async def _start_session(
    session,
    *,
    user_id: UUID,
    plan_id: UUID,
    workout_session_id: UUID,
    started_at: datetime,
    timezone: str,
    active_device_id: UUID,
) -> WorkoutSessionResponse:
    """Create one resumable workout from a published plan, with item snapshots.

    Shared by the REST route and the offline sync journal.  Raises
    HTTPException exactly as the route did, so callers translate it.
    """

    template = (
        await session.execute(
            text(
                """
                SELECT
                    p.id AS plan_id,
                    p.name AS plan_name,
                    pv.id AS plan_version_id,
                    pv.version_no AS plan_version_no,
                    pv.is_published,
                    st.id AS template_id
                FROM plans AS p
                JOIN plan_versions AS pv
                  ON pv.plan_id = p.id AND pv.version_no = p.current_version_no
                LEFT JOIN session_templates AS st ON st.plan_version_id = pv.id
                WHERE p.id = :plan_id
                  AND p.status = 'active'
                  AND p.deleted_at IS NULL
                """
            ),
            {"plan_id": plan_id},
        )
    ).mappings().one_or_none()
    if template is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Plan not found")
    if template["is_published"] is not True:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Publish this training plan before starting it.",
        )
    if template["template_id"] is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="The published plan has no executable stages.",
        )

    active_id = await session.scalar(
        text(
            """
            SELECT id FROM workout_sessions
            WHERE user_id = :user_id
              AND status = 'in_progress' AND deleted_at IS NULL
            ORDER BY started_at DESC, id DESC
            LIMIT 1
            """
        ),
        {"user_id": user_id},
    )
    if active_id is not None:
        active = await _workout_response(session, active_id)
        if active is not None and active.source_plan_id == template["plan_id"]:
            # Starting the same plan is a resume operation, never a second
            # unfinished workout.
            return active
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Finish or abandon the current workout before starting another plan.",
        )

    source_rows = await session.execute(
        text(
            """
            SELECT
                es.id AS slot_id, es.exercise_id, es.exercise_version_no, es.sort_order,
                ev.name_zh, ev.name_en, ev.summary, ev.recording_mode,
                pr.prescription_type, pr.set_count, pr.rep_min, pr.rep_max, pr.target_load_kg,
                pr.target_rpe, pr.target_rir, pr.rest_seconds, pr.tempo,
                pr.parameters_json, pr.progression_policy_json
            FROM stage_blocks AS sb
            JOIN exercise_slots AS es ON es.stage_block_id = sb.id
            JOIN exercise_versions AS ev
              ON ev.exercise_id = es.exercise_id AND ev.version_no = es.exercise_version_no
            JOIN prescriptions AS pr ON pr.exercise_slot_id = es.id
            WHERE sb.session_template_id = :template_id
            ORDER BY sb.sort_order, es.sort_order
            """
        ),
        {"template_id": template["template_id"]},
    )
    sources = list(source_rows.mappings())
    if not sources:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="The plan has no executable exercise slots.",
        )

    session_snapshot = {
        "plan_id": str(template["plan_id"]),
        "plan_name": template["plan_name"],
        # Keep an immutable version reference in both relational form and
        # the JSON snapshot.  Plan names/stages can be edited later, but a
        # recorded workout must always say exactly what it came from.
        "plan_version_id": str(template["plan_version_id"]),
        "plan_version_no": int(template["plan_version_no"]),
    }
    await session.execute(
        text(
            """
            INSERT INTO workout_sessions (
                id, user_id, source_plan_version_id, source_session_template_id,
                session_snapshot, status, started_at, timezone, active_device_id
            ) VALUES (
                :id, :user_id, :source_plan_version_id, :source_session_template_id,
                CAST(:session_snapshot AS jsonb), 'in_progress', :started_at, :timezone, :active_device_id
            )
            """
        ),
        {
            "id": workout_session_id,
            "user_id": user_id,
            "source_plan_version_id": template["plan_version_id"],
            "source_session_template_id": template["template_id"],
            "session_snapshot": json.dumps(session_snapshot, ensure_ascii=False),
            "started_at": started_at,
            "timezone": timezone,
            "active_device_id": active_device_id,
        },
    )
    for item_index, row in enumerate(sources, start=1):
        exercise_snapshot = {
            "name_zh": row["name_zh"],
            "name_en": row["name_en"],
            "summary": row["summary"],
            "recording_mode": row["recording_mode"],
        }
        prescription_snapshot = {
            "prescription_type": row["prescription_type"],
            "set_count": row["set_count"],
            "rep_min": row["rep_min"],
            "rep_max": row["rep_max"],
            "target_load_kg": _as_number(row["target_load_kg"]),
            "target_rpe": _as_number(row["target_rpe"]),
            "target_rir": _as_number(row["target_rir"]),
            "rest_seconds": row["rest_seconds"],
            "tempo": row["tempo"],
            "parameters": row["parameters_json"],
            "progression_policy": row["progression_policy_json"],
        }
        await session.execute(
            text(
                """
                INSERT INTO workout_items (
                    id, workout_session_id, source_slot_id, exercise_id, exercise_version_no,
                    exercise_snapshot, prescription_snapshot, sort_order
                ) VALUES (
                    :id, :workout_session_id, :source_slot_id, :exercise_id, :exercise_version_no,
                    CAST(:exercise_snapshot AS jsonb), CAST(:prescription_snapshot AS jsonb), :sort_order
                )
                """
            ),
            {
                "id": uuid4(),
                "workout_session_id": workout_session_id,
                "source_slot_id": row["slot_id"],
                "exercise_id": row["exercise_id"],
                "exercise_version_no": row["exercise_version_no"],
                "exercise_snapshot": json.dumps(exercise_snapshot, ensure_ascii=False),
                "prescription_snapshot": json.dumps(prescription_snapshot, ensure_ascii=False),
                "sort_order": item_index,
            },
        )

    items = await _session_items(session, workout_session_id)

    return WorkoutSessionResponse(
        id=workout_session_id,
        source_plan_id=template["plan_id"],
        source_plan_version_no=int(template["plan_version_no"]),
        status="in_progress",
        started_at=started_at,
        ended_at=None,
        timezone=timezone,
        items=items,
        plan_name=template["plan_name"],
    )


@router.post(
    "/from-plan/{plan_id}",
    response_model=WorkoutSessionResponse,
    status_code=status.HTTP_201_CREATED,
)
async def start_workout(
    plan_id: UUID,
    request: StartWorkoutRequest,
    principal: Annotated[Principal, Depends(require_principal)],
) -> WorkoutSessionResponse:
    now = request.started_at or datetime.now(UTC)
    workout_session_id = uuid4()

    async with user_transaction(principal.user_id) as session:
        return await _start_session(
            session,
            user_id=principal.user_id,
            plan_id=plan_id,
            workout_session_id=workout_session_id,
            started_at=now,
            timezone=request.timezone,
            active_device_id=principal.device_id,
        )


@router.get("/active", response_model=ActiveWorkoutResponse)
async def get_active_workout(
    principal: Annotated[Principal, Depends(require_principal)],
) -> ActiveWorkoutResponse:
    """Return the current resumable workout, if one exists for this user."""

    async with user_transaction(principal.user_id) as session:
        workout_session_id = await session.scalar(
            text(
                """
                SELECT id FROM workout_sessions
                WHERE user_id = :user_id
                  AND status = 'in_progress' AND deleted_at IS NULL
                ORDER BY started_at DESC, id DESC
                LIMIT 1
                """
            ),
            {"user_id": principal.user_id},
        )
        workout = (
            await _workout_response(session, workout_session_id)
            if workout_session_id is not None
            else None
        )
    return ActiveWorkoutResponse(workout=workout)


@router.get("/history", response_model=WorkoutHistoryPageResponse)
async def list_workout_history(
    principal: Annotated[Principal, Depends(require_principal)],
    from_at: Annotated[datetime | None, Query()] = None,
    to_at: Annotated[datetime | None, Query()] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> WorkoutHistoryPageResponse:
    """Return a compact, user-scoped history suitable for the progress timeline."""

    if from_at is not None and to_at is not None and from_at > to_at:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="from_at must not exceed to_at")

    async with user_transaction(principal.user_id) as session:
        result = await session.execute(
            text(
                """
                SELECT
                    ws.id,
                    ws.status,
                    ws.started_at,
                    ws.ended_at,
                    ws.timezone,
                    ws.session_snapshot ->> 'plan_name' AS plan_name,
                    COUNT(DISTINCT wi.id) AS item_count,
                    COUNT(sl.id) FILTER (
                        WHERE sl.status = 'completed'
                    ) AS completed_set_count,
                    COALESCE(
                        SUM(sl.load_kg * sl.reps) FILTER (
                            WHERE sl.status = 'completed'
                              AND sl.load_kg IS NOT NULL
                              AND sl.reps IS NOT NULL
                        ),
                        0
                    )::double precision AS completed_volume_kg
                FROM workout_sessions AS ws
                LEFT JOIN workout_items AS wi ON wi.workout_session_id = ws.id
                LEFT JOIN set_logs AS sl ON sl.workout_item_id = wi.id
                WHERE ws.deleted_at IS NULL
                  AND ws.status = 'completed'
                  AND (CAST(:from_at AS timestamptz) IS NULL OR ws.started_at >= CAST(:from_at AS timestamptz))
                  AND (CAST(:to_at AS timestamptz) IS NULL OR ws.started_at <= CAST(:to_at AS timestamptz))
                GROUP BY ws.id, ws.status, ws.started_at, ws.ended_at, ws.timezone, ws.session_snapshot
                ORDER BY ws.started_at DESC, ws.id DESC
                LIMIT :limit OFFSET :offset
                """
            ),
            {"from_at": from_at, "to_at": to_at, "limit": limit, "offset": offset},
        )
        entries = [WorkoutHistoryEntryResponse.model_validate(row) for row in result.mappings()]

    return WorkoutHistoryPageResponse(entries=entries, limit=limit, offset=offset)


@router.get("/{workout_session_id}", response_model=WorkoutSessionResponse)
async def get_workout(
    workout_session_id: UUID,
    principal: Annotated[Principal, Depends(require_principal)],
) -> WorkoutSessionResponse:
    async with user_transaction(principal.user_id) as session:
        workout = await _workout_response(session, workout_session_id)
        if workout is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Workout session not found")
    return workout


@router.post("/{workout_session_id}/abandon", response_model=WorkoutSessionResponse)
async def abandon_workout(
    workout_session_id: UUID,
    principal: Annotated[Principal, Depends(require_principal)],
) -> WorkoutSessionResponse:
    """Explicitly close an unfinished workout so it cannot reappear as resumable."""

    ended_at = datetime.now(UTC)
    async with user_transaction(principal.user_id) as session:
        changed = await session.scalar(
            text(
                """
                UPDATE workout_sessions
                SET status = 'abandoned', ended_at = :ended_at,
                    updated_at = now(), revision = revision + 1
                WHERE id = :workout_session_id
                  AND status = 'in_progress'
                  AND deleted_at IS NULL
                RETURNING id
                """
            ),
            {"workout_session_id": workout_session_id, "ended_at": ended_at},
        )
        if changed is None:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Workout session is unavailable or already finalized.",
            )
        workout = await _workout_response(session, workout_session_id)
    if workout is None:  # defensive: the update above proves it existed.
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Workout session not found")
    return workout


@router.put(
    "/{workout_session_id}/items/{workout_item_id}/sets/{set_number}",
    response_model=SetLogResponse,
)
async def upsert_set_log(
    workout_session_id: UUID,
    workout_item_id: UUID,
    set_number: int,
    request: SetLogInput,
    principal: Annotated[Principal, Depends(require_principal)],
) -> SetLogResponse:
    if set_number < 1 or set_number > 100:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="Set number must be 1 to 100")
    performed_at = request.performed_at or datetime.now(UTC)

    async with user_transaction(principal.user_id) as session:
        valid_item = await session.scalar(
            text(
                """
                SELECT wi.id
                FROM workout_items AS wi
                JOIN workout_sessions AS ws ON ws.id = wi.workout_session_id
                WHERE wi.id = :workout_item_id
                  AND ws.id = :workout_session_id
                  AND ws.status = 'in_progress'
                  AND ws.deleted_at IS NULL
                FOR UPDATE OF ws
                """
            ),
            {"workout_item_id": workout_item_id, "workout_session_id": workout_session_id},
        )
        if valid_item is None:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Workout item is unavailable or the session is no longer in progress.",
            )
        set_data = request.model_dump()
        set_data["performed_at"] = performed_at
        row = (
            await session.execute(
                text(
                    """
                    INSERT INTO set_logs (
                        id, workout_item_id, set_number, set_type, status, load_kg, original_load,
                        original_unit, is_per_side, includes_bar, reps, duration_seconds, distance_meters,
                        rpe, rir, pain_score, technique_ok, notes, performed_at
                    ) VALUES (
                        :id, :workout_item_id, :set_number, :set_type, :status, :load_kg, :original_load,
                        :original_unit, :is_per_side, :includes_bar, :reps, :duration_seconds,
                        :distance_meters, :rpe, :rir, :pain_score, :technique_ok, :notes, :performed_at
                    )
                    ON CONFLICT (workout_item_id, set_number) DO UPDATE SET
                        set_type = EXCLUDED.set_type,
                        status = EXCLUDED.status,
                        load_kg = EXCLUDED.load_kg,
                        original_load = EXCLUDED.original_load,
                        original_unit = EXCLUDED.original_unit,
                        is_per_side = EXCLUDED.is_per_side,
                        includes_bar = EXCLUDED.includes_bar,
                        reps = EXCLUDED.reps,
                        duration_seconds = EXCLUDED.duration_seconds,
                        distance_meters = EXCLUDED.distance_meters,
                        rpe = EXCLUDED.rpe,
                        rir = EXCLUDED.rir,
                        pain_score = EXCLUDED.pain_score,
                        technique_ok = EXCLUDED.technique_ok,
                        notes = EXCLUDED.notes,
                        performed_at = EXCLUDED.performed_at,
                        updated_at = now(),
                        revision = set_logs.revision + 1
                    RETURNING id
                    """
                ),
                {"id": uuid4(), "workout_item_id": workout_item_id, "set_number": set_number, **set_data},
            )
        ).mappings().one()

    return SetLogResponse(id=row["id"], set_number=set_number, **set_data)


@router.post("/{workout_session_id}/complete", response_model=CompleteWorkoutResponse)
async def complete_workout(
    workout_session_id: UUID,
    principal: Annotated[Principal, Depends(require_principal)],
) -> CompleteWorkoutResponse:
    ended_at = datetime.now(UTC)
    async with user_transaction(principal.user_id) as session:
        row = (
            await session.execute(
                text(
                    """
                    UPDATE workout_sessions
                    SET status = 'completed', ended_at = :ended_at, updated_at = now(), revision = revision + 1
                    WHERE id = :workout_session_id AND status = 'in_progress' AND deleted_at IS NULL
                    RETURNING id
                    """
                ),
                {"workout_session_id": workout_session_id, "ended_at": ended_at},
            )
        ).mappings().one_or_none()
        if row is None:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Workout session is unavailable or already finalized.",
            )
    return CompleteWorkoutResponse(id=row["id"], status="completed", ended_at=ended_at)
