from __future__ import annotations

import json
from typing import Annotated
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import text

from app.api.dependencies import Principal, require_principal
from app.api.schemas import (
    CreatePlanRequest,
    PlanAlternativeResponse,
    PlanBlockResponse,
    PlanDetailResponse,
    PlanSlotResponse,
    PlanStageBlockInput,
    PlanSummaryResponse,
    PlanVersionResponse,
    PrescriptionInput,
    PublishPlanVersionRequest,
    ReplacePlanVersionRequest,
)
from app.db.session import user_transaction

router = APIRouter(prefix="/v1/plans", tags=["plans"])


async def _published_version_for_exercise(
    session,
    exercise_id: UUID,
    requested_version_no: int | None,
) -> int:
    row = (
        await session.execute(
            text(
                """
                SELECT COALESCE(
                    (
                        SELECT e.current_published_version
                        FROM exercises AS e
                        WHERE e.id = :exercise_id
                          AND e.status = 'published'
                          AND CAST(:requested_version_no AS integer) IS NULL
                    ),
                    (
                        SELECT ev.version_no
                        FROM exercise_versions AS ev
                        JOIN exercises AS e ON e.id = ev.exercise_id
                        WHERE ev.exercise_id = :exercise_id
                          AND ev.version_no = CAST(:requested_version_no AS integer)
                          AND ev.status = 'published'
                          AND e.status = 'published'
                    )
                )
                """
            ),
            {"exercise_id": exercise_id, "requested_version_no": requested_version_no},
        )
    ).scalar_one_or_none()
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=f"Exercise {exercise_id} does not have the requested published version.",
        )
    return int(row)


async def _insert_version_content(
    session,
    plan_version_id: UUID,
    plan_name: str,
    blocks: list[PlanStageBlockInput],
) -> None:
    """Persist one training template and its ordered stages.

    ``session_templates`` remains an internal relational container while old
    workout records reference it.  The public plan model deliberately never
    exposes it: every plan version gets exactly one such container.
    """

    template_id = uuid4()
    await session.execute(
        text(
            """
            INSERT INTO session_templates (
                id, plan_version_id, name, weekday, estimated_duration_seconds, sort_order
            ) VALUES (:id, :plan_version_id, :name, NULL, NULL, 1)
            """
        ),
        {"id": template_id, "plan_version_id": plan_version_id, "name": plan_name},
    )

    for block_index, block_input in enumerate(blocks, start=1):
        block_id = uuid4()
        await session.execute(
            text(
                """
                INSERT INTO stage_blocks (
                    id, session_template_id, purpose, custom_name, config_json, sort_order
                ) VALUES (
                    :id, :session_template_id, :purpose, :custom_name,
                    CAST(:config_json AS jsonb), :sort_order
                )
                """
            ),
            {
                "id": block_id,
                "session_template_id": template_id,
                "purpose": block_input.purpose,
                "custom_name": block_input.custom_name,
                "config_json": json.dumps(block_input.config, ensure_ascii=False),
                "sort_order": block_index,
            },
        )
        for slot_index, slot_input in enumerate(block_input.slots, start=1):
            published_version_no = await _published_version_for_exercise(
                session, slot_input.exercise_id, slot_input.exercise_version_no
            )
            slot_id = uuid4()
            await session.execute(
                text(
                    """
                    INSERT INTO exercise_slots (
                        id, stage_block_id, exercise_id, exercise_version_no, group_id,
                        group_type, side_mode, sort_order
                    ) VALUES (
                        :id, :stage_block_id, :exercise_id, :exercise_version_no, :group_id,
                        :group_type, :side_mode, :sort_order
                    )
                    """
                ),
                {
                    "id": slot_id,
                    "stage_block_id": block_id,
                    "exercise_id": slot_input.exercise_id,
                    "exercise_version_no": published_version_no,
                    "group_id": slot_input.group_id,
                    "group_type": slot_input.group_type,
                    "side_mode": slot_input.side_mode,
                    "sort_order": slot_index,
                },
            )
            prescription = slot_input.prescription
            await session.execute(
                text(
                    """
                    INSERT INTO prescriptions (
                        id, exercise_slot_id, prescription_type, set_count, rep_min, rep_max,
                        target_load_kg, target_rpe, target_rir, rest_seconds, tempo,
                        parameters_json, progression_policy_json
                    ) VALUES (
                        :id, :exercise_slot_id, :prescription_type, :set_count, :rep_min, :rep_max,
                        :target_load_kg, :target_rpe, :target_rir, :rest_seconds, :tempo,
                        CAST(:parameters_json AS jsonb), CAST(:progression_policy_json AS jsonb)
                    )
                    """
                ),
                {
                    "id": uuid4(),
                    "exercise_slot_id": slot_id,
                    "prescription_type": prescription.prescription_type,
                    "set_count": prescription.set_count,
                    "rep_min": prescription.rep_min,
                    "rep_max": prescription.rep_max,
                    "target_load_kg": prescription.target_load_kg,
                    "target_rpe": prescription.target_rpe,
                    "target_rir": prescription.target_rir,
                    "rest_seconds": prescription.rest_seconds,
                    "tempo": prescription.tempo,
                    "parameters_json": json.dumps(prescription.parameters, ensure_ascii=False),
                    "progression_policy_json": json.dumps(
                        prescription.progression_policy, ensure_ascii=False
                    ),
                },
            )
            for alternative_index, alternative in enumerate(slot_input.alternatives, start=1):
                # Alternatives must be selectable published actions, same as the
                # main exercise, so an offline replacement never points at a
                # withdrawn action.
                await _published_version_for_exercise(session, alternative.exercise_id, None)
                await session.execute(
                    text(
                        """
                        INSERT INTO slot_alternatives (
                            id, exercise_slot_id, alternative_exercise_id, rule_json, priority
                        ) VALUES (
                            :id, :exercise_slot_id, :alternative_exercise_id,
                            CAST(:rule_json AS jsonb), :priority
                        )
                        """
                    ),
                    {
                        "id": uuid4(),
                        "exercise_slot_id": slot_id,
                        "alternative_exercise_id": alternative.exercise_id,
                        "rule_json": json.dumps(alternative.rule_json, ensure_ascii=False),
                        "priority": alternative.priority or alternative_index,
                    },
                )


async def _clone_version_content(session, source_version_id: UUID, target_version_id: UUID) -> None:
    """Copy the internal single-template graph with fresh relational IDs."""

    source_template = (
        await session.execute(
            text(
                """
                SELECT id, name
                FROM session_templates
                WHERE plan_version_id = :plan_version_id
                ORDER BY sort_order
                """
            ),
            {"plan_version_id": source_version_id},
        )
    ).mappings().one_or_none()
    if source_template is None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="The current plan version has no training template to copy.",
        )

    target_template_id = uuid4()
    await session.execute(
        text(
            """
            INSERT INTO session_templates (
                id, plan_version_id, name, weekday, estimated_duration_seconds, sort_order
            ) VALUES (:id, :plan_version_id, :name, NULL, NULL, 1)
            """
        ),
        {
            "id": target_template_id,
            "plan_version_id": target_version_id,
            "name": source_template["name"],
        },
    )
    block_rows = await session.execute(
        text(
            """
            SELECT id, purpose, custom_name, config_json, sort_order
            FROM stage_blocks
            WHERE session_template_id = :session_template_id
            ORDER BY sort_order
            """
        ),
        {"session_template_id": source_template["id"]},
    )
    for block in block_rows.mappings():
        target_block_id = uuid4()
        await session.execute(
            text(
                """
                INSERT INTO stage_blocks (
                    id, session_template_id, purpose, custom_name, config_json, sort_order
                ) VALUES (
                    :id, :session_template_id, :purpose, :custom_name,
                    CAST(:config_json AS jsonb), :sort_order
                )
                """
            ),
            {
                "id": target_block_id,
                "session_template_id": target_template_id,
                "purpose": block["purpose"],
                "custom_name": block["custom_name"],
                "config_json": json.dumps(block["config_json"], ensure_ascii=False),
                "sort_order": block["sort_order"],
            },
        )
        slot_rows = await session.execute(
            text(
                """
                SELECT
                    slot.id, slot.exercise_id, slot.exercise_version_no, slot.group_id,
                    slot.group_type, slot.side_mode, slot.sort_order,
                    prescription.prescription_type, prescription.set_count, prescription.rep_min,
                    prescription.rep_max, prescription.target_load_kg, prescription.target_rpe,
                    prescription.target_rir, prescription.rest_seconds, prescription.tempo,
                    prescription.parameters_json, prescription.progression_policy_json
                FROM exercise_slots AS slot
                JOIN prescriptions AS prescription ON prescription.exercise_slot_id = slot.id
                WHERE slot.stage_block_id = :stage_block_id
                ORDER BY slot.sort_order
                """
            ),
            {"stage_block_id": block["id"]},
        )
        for slot in slot_rows.mappings():
            target_slot_id = uuid4()
            await session.execute(
                text(
                    """
                    INSERT INTO exercise_slots (
                        id, stage_block_id, exercise_id, exercise_version_no, group_id,
                        group_type, side_mode, sort_order
                    ) VALUES (
                        :id, :stage_block_id, :exercise_id, :exercise_version_no, :group_id,
                        :group_type, :side_mode, :sort_order
                    )
                    """
                ),
                {
                    "id": target_slot_id,
                    "stage_block_id": target_block_id,
                    "exercise_id": slot["exercise_id"],
                    "exercise_version_no": slot["exercise_version_no"],
                    "group_id": slot["group_id"],
                    "group_type": slot["group_type"],
                    "side_mode": slot["side_mode"],
                    "sort_order": slot["sort_order"],
                },
            )
            await session.execute(
                text(
                    """
                    INSERT INTO prescriptions (
                        id, exercise_slot_id, prescription_type, set_count, rep_min, rep_max,
                        target_load_kg, target_rpe, target_rir, rest_seconds, tempo,
                        parameters_json, progression_policy_json
                    ) VALUES (
                        :id, :exercise_slot_id, :prescription_type, :set_count, :rep_min, :rep_max,
                        :target_load_kg, :target_rpe, :target_rir, :rest_seconds, :tempo,
                        CAST(:parameters_json AS jsonb), CAST(:progression_policy_json AS jsonb)
                    )
                    """
                ),
                {
                    "id": uuid4(),
                    "exercise_slot_id": target_slot_id,
                    "prescription_type": slot["prescription_type"],
                    "set_count": slot["set_count"],
                    "rep_min": slot["rep_min"],
                    "rep_max": slot["rep_max"],
                    "target_load_kg": slot["target_load_kg"],
                    "target_rpe": slot["target_rpe"],
                    "target_rir": slot["target_rir"],
                    "rest_seconds": slot["rest_seconds"],
                    "tempo": slot["tempo"],
                    "parameters_json": json.dumps(slot["parameters_json"], ensure_ascii=False),
                    "progression_policy_json": json.dumps(
                        slot["progression_policy_json"], ensure_ascii=False
                    ),
                },
            )
            alternative_rows = await session.execute(
                text(
                    """
                    SELECT alternative_exercise_id, rule_json, priority
                    FROM slot_alternatives
                    WHERE exercise_slot_id = :exercise_slot_id
                    ORDER BY priority, id
                    """
                ),
                {"exercise_slot_id": slot["id"]},
            )
            for alternative in alternative_rows.mappings():
                await session.execute(
                    text(
                        """
                        INSERT INTO slot_alternatives (
                            id, exercise_slot_id, alternative_exercise_id, rule_json, priority
                        ) VALUES (
                            :id, :exercise_slot_id, :alternative_exercise_id,
                            CAST(:rule_json AS jsonb), :priority
                        )
                        """
                    ),
                    {
                        "id": uuid4(),
                        "exercise_slot_id": target_slot_id,
                        "alternative_exercise_id": alternative["alternative_exercise_id"],
                        "rule_json": json.dumps(alternative["rule_json"], ensure_ascii=False),
                        "priority": alternative["priority"],
                    },
                )


async def _version_blocks(session, plan_version_id: UUID) -> list[PlanBlockResponse]:
    rows = await session.execute(
        text(
            """
            SELECT
                sb.id AS block_id, sb.purpose, sb.custom_name, sb.config_json,
                sb.sort_order AS block_sort_order,
                es.id AS slot_id, es.exercise_id, es.exercise_version_no, ev.name_zh AS exercise_name_zh,
                es.group_id, es.group_type, es.side_mode, es.sort_order AS slot_sort_order,
                pr.prescription_type, pr.set_count, pr.rep_min, pr.rep_max, pr.target_load_kg,
                pr.target_rpe, pr.target_rir, pr.rest_seconds, pr.tempo, pr.parameters_json,
                pr.progression_policy_json
            FROM session_templates AS st
            JOIN stage_blocks AS sb ON sb.session_template_id = st.id
            JOIN exercise_slots AS es ON es.stage_block_id = sb.id
            JOIN exercise_versions AS ev
              ON ev.exercise_id = es.exercise_id AND ev.version_no = es.exercise_version_no
            JOIN prescriptions AS pr ON pr.exercise_slot_id = es.id
            WHERE st.plan_version_id = :plan_version_id
            ORDER BY sb.sort_order, es.sort_order
            """
        ),
        {"plan_version_id": plan_version_id},
    )
    alternative_rows = await session.execute(
        text(
            """
            SELECT
                sa.exercise_slot_id, sa.alternative_exercise_id,
                alternative_ev.name_zh AS alternative_name_zh,
                sa.rule_json, sa.priority
            FROM slot_alternatives AS sa
            JOIN exercises AS alternative_e ON alternative_e.id = sa.alternative_exercise_id
            JOIN exercise_versions AS alternative_ev
              ON alternative_ev.exercise_id = alternative_e.id
             AND alternative_ev.version_no = alternative_e.current_published_version
            WHERE sa.exercise_slot_id IN (
                SELECT es.id
                FROM session_templates AS st
                JOIN stage_blocks AS sb ON sb.session_template_id = st.id
                JOIN exercise_slots AS es ON es.stage_block_id = sb.id
                WHERE st.plan_version_id = :plan_version_id
            )
            ORDER BY sa.priority
            """
        ),
        {"plan_version_id": plan_version_id},
    )
    alternatives_by_slot: dict[UUID, list[PlanAlternativeResponse]] = {}
    for alternative in alternative_rows.mappings():
        alternatives_by_slot.setdefault(alternative["exercise_slot_id"], []).append(
            PlanAlternativeResponse(
                exercise_id=alternative["alternative_exercise_id"],
                exercise_name_zh=str(alternative["alternative_name_zh"]),
                rule_json=alternative["rule_json"],
                priority=int(alternative["priority"]),
            )
        )
    blocks: dict[UUID, dict[str, object]] = {}
    for row in rows.mappings():
        block_id = row["block_id"]
        block = blocks.setdefault(
            block_id,
            {
                "id": block_id,
                "purpose": row["purpose"],
                "custom_name": row["custom_name"],
                "config": row["config_json"],
                "sort_order": row["block_sort_order"],
                "slots": [],
            },
        )
        slots: list[PlanSlotResponse] = block["slots"]  # type: ignore[assignment]
        slots.append(
            PlanSlotResponse(
                id=row["slot_id"],
                exercise_id=row["exercise_id"],
                exercise_version_no=row["exercise_version_no"],
                exercise_name_zh=row["exercise_name_zh"],
                group_id=row["group_id"],
                group_type=row["group_type"],
                side_mode=row["side_mode"],
                prescription=PrescriptionInput(
                    prescription_type=row["prescription_type"],
                    set_count=row["set_count"],
                    rep_min=row["rep_min"],
                    rep_max=row["rep_max"],
                    target_load_kg=float(row["target_load_kg"])
                    if row["target_load_kg"] is not None
                    else None,
                    target_rpe=float(row["target_rpe"])
                    if row["target_rpe"] is not None
                    else None,
                    target_rir=float(row["target_rir"])
                    if row["target_rir"] is not None
                    else None,
                    rest_seconds=row["rest_seconds"],
                    tempo=row["tempo"],
                    parameters=row["parameters_json"],
                    progression_policy=row["progression_policy_json"],
                ),
                alternatives=alternatives_by_slot.get(row["slot_id"], []),
                sort_order=row["slot_sort_order"],
            )
        )
    return [
        PlanBlockResponse(
            id=block["id"],
            purpose=block["purpose"],
            custom_name=block["custom_name"],
            config=block["config"],
            sort_order=block["sort_order"],
            slots=block["slots"],
        )
        for block in sorted(blocks.values(), key=lambda item: item["sort_order"])
    ]


@router.post("", response_model=PlanSummaryResponse, status_code=status.HTTP_201_CREATED)
async def create_plan(
    request: CreatePlanRequest,
    principal: Annotated[Principal, Depends(require_principal)],
) -> PlanSummaryResponse:
    """Create an editable training-template canvas.

    The canvas may be empty.  A version only becomes executable after its
    caller explicitly publishes it, at which point at least one action is
    required.
    """

    plan_id = uuid4()
    plan_version_id = uuid4()
    async with user_transaction(principal.user_id) as session:
        await session.execute(
            text(
                """
                INSERT INTO plans (id, user_id, name, goal_json, current_version_no, status)
                VALUES (:id, :user_id, :name, CAST(:goal_json AS jsonb), 1, 'active')
                """
            ),
            {
                "id": plan_id,
                "user_id": principal.user_id,
                "name": request.name,
                "goal_json": json.dumps(request.goal, ensure_ascii=False),
            },
        )
        await session.execute(
            text(
                """
                INSERT INTO plan_versions (id, plan_id, version_no, is_published)
                VALUES (:id, :plan_id, 1, false)
                """
            ),
            {"id": plan_version_id, "plan_id": plan_id},
        )
        await _insert_version_content(session, plan_version_id, request.name, request.blocks)

    return PlanSummaryResponse(
        id=plan_id,
        name=request.name,
        current_version_no=1,
        status="active",
        is_published=False,
        revision=1,
        block_count=len(request.blocks),
        exercise_slot_count=sum(len(block.slots) for block in request.blocks),
    )


async def _create_draft_version(session, plan_id: UUID) -> dict[str, object]:
    """Create the single editable successor draft of a plan's current version.

    Shared by the REST route and the offline sync journal.  Raises
    HTTPException exactly as the route did, so callers translate it.
    """

    plan = (
        await session.execute(
            text(
                """
                SELECT p.id, p.current_version_no, current_version.id AS current_version_id
                FROM plans AS p
                JOIN plan_versions AS current_version
                  ON current_version.plan_id = p.id
                 AND current_version.version_no = p.current_version_no
                WHERE p.id = :plan_id AND p.deleted_at IS NULL
                FOR UPDATE OF p
                """
            ),
            {"plan_id": plan_id},
        )
    ).mappings().one_or_none()
    if plan is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Plan not found")

    existing_draft = await session.scalar(
        text(
            """
            SELECT version_no
            FROM plan_versions
            WHERE plan_id = :plan_id AND is_published = false
            ORDER BY version_no DESC
            LIMIT 1
            """
        ),
        {"plan_id": plan_id},
    )
    if existing_draft is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"message": "A draft version is already open.", "version_no": int(existing_draft)},
        )

    next_version_no = int(
        await session.scalar(
            text("SELECT COALESCE(MAX(version_no), 0) + 1 FROM plan_versions WHERE plan_id = :plan_id"),
            {"plan_id": plan_id},
        )
    )
    draft_id = uuid4()
    await session.execute(
        text(
            """
            INSERT INTO plan_versions (
                id, plan_id, version_no, based_on_version_no, is_published
            ) VALUES (
                :id, :plan_id, :version_no, :based_on_version_no, false
            )
            """
        ),
        {
            "id": draft_id,
            "plan_id": plan_id,
            "version_no": next_version_no,
            "based_on_version_no": plan["current_version_no"],
        },
    )
    await _clone_version_content(session, plan["current_version_id"], draft_id)

    return {
        "id": draft_id,
        "plan_id": plan_id,
        "version_no": next_version_no,
        "based_on_version_no": plan["current_version_no"],
        "is_published": False,
        "revision": 1,
    }


@router.post("/{plan_id}/versions", response_model=PlanVersionResponse, status_code=status.HTTP_201_CREATED)
async def create_plan_version(
    plan_id: UUID,
    principal: Annotated[Principal, Depends(require_principal)],
) -> PlanVersionResponse:
    """Clone the current immutable plan into its one editable draft."""

    async with user_transaction(principal.user_id) as session:
        draft = await _create_draft_version(session, plan_id)

    return PlanVersionResponse(**draft)


@router.put("/{plan_id}/versions/{version_no}", response_model=PlanVersionResponse)
async def replace_plan_version(
    plan_id: UUID,
    version_no: int,
    request: ReplacePlanVersionRequest,
    principal: Annotated[Principal, Depends(require_principal)],
) -> PlanVersionResponse:
    """Atomically replace every stage of one unpublished plan version."""

    async with user_transaction(principal.user_id) as session:
        version = (
            await session.execute(
                text(
                    """
                    SELECT pv.id, pv.plan_id, pv.version_no, pv.based_on_version_no,
                           pv.is_published, pv.revision, p.name AS plan_name
                    FROM plan_versions AS pv
                    JOIN plans AS p ON p.id = pv.plan_id
                    WHERE pv.plan_id = :plan_id
                      AND pv.version_no = :version_no
                      AND p.deleted_at IS NULL
                    FOR UPDATE OF pv
                    """
                ),
                {"plan_id": plan_id, "version_no": version_no},
            )
        ).mappings().one_or_none()
        if version is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Plan version not found")
        if version["is_published"]:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Published plan versions are immutable; create a draft copy first.",
            )
        if int(version["revision"]) != request.base_revision:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={
                    "message": "The draft changed on another device.",
                    "current_revision": int(version["revision"]),
                },
            )

        # Drafts are never executable.  Their internal container and all child
        # rows can therefore be safely replaced as one transaction.
        await session.execute(
            text("DELETE FROM session_templates WHERE plan_version_id = :plan_version_id"),
            {"plan_version_id": version["id"]},
        )
        await _insert_version_content(session, version["id"], version["plan_name"], request.blocks)
        updated_revision = int(
            await session.scalar(
                text(
                    """
                    UPDATE plan_versions
                    SET revision = revision + 1, updated_at = now()
                    WHERE id = :plan_version_id
                    RETURNING revision
                    """
                ),
                {"plan_version_id": version["id"]},
            )
        )

    return PlanVersionResponse(
        id=version["id"],
        plan_id=version["plan_id"],
        version_no=version["version_no"],
        based_on_version_no=version["based_on_version_no"],
        is_published=False,
        revision=updated_revision,
    )


@router.post("/{plan_id}/versions/{version_no}/publish", response_model=PlanVersionResponse)
async def publish_plan_version(
    plan_id: UUID,
    version_no: int,
    request: PublishPlanVersionRequest,
    principal: Annotated[Principal, Depends(require_principal)],
) -> PlanVersionResponse:
    """Make a fully written draft the current immutable training template."""

    async with user_transaction(principal.user_id) as session:
        version = (
            await session.execute(
                text(
                    """
                    SELECT pv.id, pv.plan_id, pv.version_no, pv.based_on_version_no,
                           pv.is_published, pv.revision
                    FROM plans AS p
                    JOIN plan_versions AS pv ON pv.plan_id = p.id
                    WHERE p.id = :plan_id
                      AND pv.version_no = :version_no
                      AND p.deleted_at IS NULL
                    FOR UPDATE OF p, pv
                    """
                ),
                {"plan_id": plan_id, "version_no": version_no},
            )
        ).mappings().one_or_none()
        if version is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Plan version not found")
        if version["is_published"]:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Plan version is already published")
        if int(version["revision"]) != request.base_revision:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={
                    "message": "The draft changed on another device.",
                    "current_revision": int(version["revision"]),
                },
            )

        executable_slots = await session.scalar(
            text(
                """
                SELECT EXISTS (
                    SELECT 1
                    FROM session_templates AS st
                    JOIN stage_blocks AS sb ON sb.session_template_id = st.id
                    JOIN exercise_slots AS es ON es.stage_block_id = sb.id
                    WHERE st.plan_version_id = :plan_version_id
                )
                """
            ),
            {"plan_version_id": version["id"]},
        )
        if executable_slots is not True:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="A publishable plan version needs at least one exercise slot.",
            )

        updated_revision = int(
            await session.scalar(
                text(
                    """
                    UPDATE plan_versions
                    SET is_published = true,
                        published_at = now(),
                        updated_at = now(),
                        revision = revision + 1
                    WHERE id = :plan_version_id
                    RETURNING revision
                    """
                ),
                {"plan_version_id": version["id"]},
            )
        )
        await session.execute(
            text(
                """
                UPDATE plans
                SET current_version_no = :version_no,
                    updated_at = now(),
                    revision = revision + 1
                WHERE id = :plan_id
                """
            ),
            {"plan_id": plan_id, "version_no": version["version_no"]},
        )

    return PlanVersionResponse(
        id=version["id"],
        plan_id=version["plan_id"],
        version_no=version["version_no"],
        based_on_version_no=version["based_on_version_no"],
        is_published=True,
        revision=updated_revision,
    )


@router.get("", response_model=list[PlanSummaryResponse])
async def list_plans(
    principal: Annotated[Principal, Depends(require_principal)],
) -> list[PlanSummaryResponse]:
    async with user_transaction(principal.user_id) as session:
        result = await session.execute(
            text(
                """
                SELECT
                    p.id,
                    p.name,
                    p.current_version_no,
                    p.status,
                    pv.is_published,
                    pv.revision,
                    COUNT(DISTINCT sb.id) AS block_count,
                    COUNT(es.id) AS exercise_slot_count
                FROM plans AS p
                LEFT JOIN plan_versions AS pv
                  ON pv.plan_id = p.id AND pv.version_no = p.current_version_no
                LEFT JOIN session_templates AS st ON st.plan_version_id = pv.id
                LEFT JOIN stage_blocks AS sb ON sb.session_template_id = st.id
                LEFT JOIN exercise_slots AS es ON es.stage_block_id = sb.id
                WHERE p.deleted_at IS NULL
                GROUP BY p.id, p.name, p.current_version_no, p.status, pv.is_published, pv.revision
                ORDER BY p.updated_at DESC, p.id
                """
            )
        )
        return [PlanSummaryResponse.model_validate(row) for row in result.mappings()]


@router.delete("/{plan_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_plan(
    plan_id: UUID,
    principal: Annotated[Principal, Depends(require_principal)],
) -> Response:
    """Soft-delete one training plan; past workouts keep their snapshots."""

    async with user_transaction(principal.user_id) as session:
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
                {"plan_id": plan_id},
            )
        ).mappings().one_or_none()
        if row is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Plan not found")
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/{plan_id}", response_model=PlanDetailResponse)
async def get_plan(
    plan_id: UUID,
    principal: Annotated[Principal, Depends(require_principal)],
) -> PlanDetailResponse:
    async with user_transaction(principal.user_id) as session:
        plan = (
            await session.execute(
                text(
                    """
                    SELECT
                        p.id,
                        p.name,
                        p.goal_json,
                        p.current_version_no,
                        p.status,
                        pv.id AS plan_version_id,
                        pv.is_published,
                        pv.revision
                    FROM plans AS p
                    JOIN plan_versions AS pv
                      ON pv.plan_id = p.id AND pv.version_no = p.current_version_no
                    WHERE p.id = :plan_id AND p.deleted_at IS NULL
                    """
                ),
                {"plan_id": plan_id},
            )
        ).mappings().one_or_none()
        if plan is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Plan not found")
        blocks = await _version_blocks(session, plan["plan_version_id"])

    return PlanDetailResponse(
        id=plan["id"],
        name=plan["name"],
        current_version_no=plan["current_version_no"],
        status=plan["status"],
        is_published=plan["is_published"],
        revision=plan["revision"],
        block_count=len(blocks),
        exercise_slot_count=sum(len(block.slots) for block in blocks),
        goal=plan["goal_json"],
        blocks=blocks,
    )
