"""Account ownership endpoints: full data export and account deletion.

Export returns every user-owned row as a flat JSON document (RLS already
scopes each query to the caller), so no personal data stays locked in the
service.  Deletion is soft: history rows keep their foreign keys, but the
account can no longer authenticate and every device session is revoked.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import text

from app.api.dependencies import Principal, require_principal
from app.api.schemas import AccountExportResponse
from app.db.session import system_transaction, user_transaction

router = APIRouter(prefix="/v1/account", tags=["account"])

_EXPORT_TABLES = (
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
)


@router.get("/export", response_model=AccountExportResponse)
async def export_account(
    principal: Annotated[Principal, Depends(require_principal)],
) -> AccountExportResponse:
    async with user_transaction(principal.user_id) as session:
        email = await session.scalar(
            text("SELECT email FROM users WHERE id = :user_id"),
            {"user_id": principal.user_id},
        )
        documents: dict[str, list[dict]] = {}
        for table in _EXPORT_TABLES:
            rows = await session.execute(
                text(f"SELECT to_jsonb(t) AS doc FROM {table} AS t")
            )
            documents[table] = [dict(row["doc"]) for row in rows.mappings()]

    return AccountExportResponse(
        exported_at=datetime.now(UTC),
        account={
            "user_id": str(principal.user_id),
            "email": str(email) if email else None,
        },
        documents=documents,
    )


@router.post("/delete", status_code=status.HTTP_204_NO_CONTENT)
async def delete_account(
    principal: Annotated[Principal, Depends(require_principal)],
) -> Response:
    async with system_transaction() as session:
        await session.execute(
            text(
                """
                INSERT INTO audit_logs (id, actor_user_id, action, entity_type, entity_id)
                VALUES (:id, :actor_user_id, 'delete_account', 'user', :entity_id)
                """
            ),
            {
                "id": uuid4(),
                "actor_user_id": principal.user_id,
                "entity_id": principal.user_id,
            },
        )
        changed = await session.scalar(
            text(
                """
                UPDATE users
                SET deleted_at = now(), updated_at = now()
                WHERE id = :user_id AND deleted_at IS NULL
                RETURNING id
                """
            ),
            {"user_id": principal.user_id},
        )

    if changed is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Account not found"
        )

    async with user_transaction(principal.user_id) as session:
        await session.execute(
            text(
                """
                UPDATE device_sessions
                SET revoked_at = now(), updated_at = now()
                WHERE user_id = :user_id AND revoked_at IS NULL
                """
            ),
            {"user_id": principal.user_id},
        )

    return Response(status_code=status.HTTP_204_NO_CONTENT)
