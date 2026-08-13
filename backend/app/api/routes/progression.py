from __future__ import annotations

import json
from statistics import mean
from typing import Annotated
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import text

from app.api.dependencies import Principal, require_principal
from app.api.schemas import (
    GenerateProgressionSuggestionRequest,
    ProgressionSuggestionResponse,
    SuggestionDecisionRequest,
)
from app.db.session import user_transaction

router = APIRouter(prefix="/v1/progression", tags=["progression"])

_ALGORITHM_VERSION = "rule-v1"


@router.post("/suggestions", response_model=ProgressionSuggestionResponse, status_code=status.HTTP_201_CREATED)
async def generate_suggestion(
    request: GenerateProgressionSuggestionRequest,
    principal: Annotated[Principal, Depends(require_principal)],
) -> ProgressionSuggestionResponse:
    async with user_transaction(principal.user_id) as session:
        item = (
            await session.execute(
                text(
                    """
                    SELECT wi.id, wi.source_slot_id, wi.prescription_snapshot
                    FROM workout_items AS wi
                    JOIN workout_sessions AS ws ON ws.id = wi.workout_session_id
                    WHERE wi.id = :workout_item_id
                      AND ws.status = 'completed'
                      AND ws.deleted_at IS NULL
                    """
                ),
                {"workout_item_id": request.workout_item_id},
            )
        ).mappings().one_or_none()
        if item is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="Suggestions require an item from a completed workout session.",
            )

        set_rows = await session.execute(
            text(
                """
                SELECT load_kg, reps, rpe, pain_score, technique_ok
                FROM set_logs
                WHERE workout_item_id = :workout_item_id
                  AND set_type = 'working'
                  AND status = 'completed'
                ORDER BY set_number
                """
            ),
            {"workout_item_id": request.workout_item_id},
        )
        sets = list(set_rows.mappings())
        prescription = item["prescription_snapshot"]
        target_load = prescription.get("target_load_kg")
        rep_max = prescription.get("rep_max") or prescription.get("rep_min")
        completed_reps = [int(row["reps"]) for row in sets if row["reps"] is not None]
        rpes = [float(row["rpe"]) for row in sets if row["rpe"] is not None]
        pain_scores = [int(row["pain_score"]) for row in sets if row["pain_score"] is not None]
        technique_failed = any(row["technique_ok"] is False for row in sets)
        input_summary = {
            "working_set_count": len(sets),
            "completed_reps": completed_reps,
            "average_rpe": round(mean(rpes), 1) if rpes else None,
            "max_pain_score": max(pain_scores) if pain_scores else None,
            "technique_failed": technique_failed,
            "target_load_kg": target_load,
            "rep_target": rep_max,
        }

        if not sets or target_load is None:
            suggestion = {"action": "review", "next_load_kg": target_load}
            rationale = "缺少完成组或目标重量，建议手动复核后再调整。"
        elif technique_failed or (pain_scores and max(pain_scores) >= 4):
            next_load = round(float(target_load) * 0.95, 3)
            suggestion = {"action": "reduce_load", "next_load_kg": next_load}
            rationale = "动作质量不稳定或疼痛评分偏高，建议下次先降低约 5% 负荷。"
        elif rpes and mean(rpes) >= 9.5:
            suggestion = {"action": "maintain", "next_load_kg": float(target_load)}
            rationale = "主观用力已接近极限，建议下次维持当前负荷。"
        elif rep_max is not None and completed_reps and min(completed_reps) >= int(rep_max) and (
            not rpes or mean(rpes) <= 8.0
        ):
            policy = prescription.get("progression_policy") or {}
            increment = float(policy.get("increment_kg", 2.5))
            next_load = round(float(target_load) + increment, 3)
            suggestion = {"action": "increase_load", "next_load_kg": next_load, "increment_kg": increment}
            rationale = "所有完成组达到次数目标且 RPE 可控，建议下次小幅加重。"
        else:
            suggestion = {"action": "maintain", "next_load_kg": float(target_load)}
            rationale = "当前表现尚未满足安全加重条件，建议维持负荷并继续积累完成质量。"

        suggestion_id = uuid4()
        await session.execute(
            text(
                """
                INSERT INTO progression_suggestions (
                    id, user_id, exercise_slot_id, workout_item_id, algorithm_version,
                    input_summary, suggestion_json, rationale
                ) VALUES (
                    :id, :user_id, :exercise_slot_id, :workout_item_id, :algorithm_version,
                    CAST(:input_summary AS jsonb), CAST(:suggestion_json AS jsonb), :rationale
                )
                """
            ),
            {
                "id": suggestion_id,
                "user_id": principal.user_id,
                "exercise_slot_id": item["source_slot_id"],
                "workout_item_id": request.workout_item_id,
                "algorithm_version": _ALGORITHM_VERSION,
                "input_summary": json.dumps(input_summary, ensure_ascii=False),
                "suggestion_json": json.dumps(suggestion, ensure_ascii=False),
                "rationale": rationale,
            },
        )

    return ProgressionSuggestionResponse(
        id=suggestion_id,
        workout_item_id=request.workout_item_id,
        algorithm_version=_ALGORITHM_VERSION,
        input_summary=input_summary,
        suggestion=suggestion,
        rationale=rationale,
        decision="pending",
    )


@router.patch("/suggestions/{suggestion_id}", response_model=ProgressionSuggestionResponse)
async def decide_suggestion(
    suggestion_id: UUID,
    request: SuggestionDecisionRequest,
    principal: Annotated[Principal, Depends(require_principal)],
) -> ProgressionSuggestionResponse:
    """Record the user's accept/ignore decision on one pending suggestion."""

    async with user_transaction(principal.user_id) as session:
        row = (
            await session.execute(
                text(
                    """
                    UPDATE progression_suggestions
                    SET decision = :decision, decided_at = now()
                    WHERE id = :suggestion_id AND decision = 'pending'
                    RETURNING id, workout_item_id, algorithm_version,
                              input_summary, suggestion_json, rationale, decision
                    """
                ),
                {"suggestion_id": suggestion_id, "decision": request.decision},
            )
        ).mappings().one_or_none()
        if row is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Pending suggestion not found or already decided.",
            )

    return ProgressionSuggestionResponse(
        id=row["id"],
        workout_item_id=row["workout_item_id"],
        algorithm_version=str(row["algorithm_version"]),
        input_summary=row["input_summary"],
        suggestion=row["suggestion_json"],
        rationale=str(row["rationale"]),
        decision=str(row["decision"]),
    )
