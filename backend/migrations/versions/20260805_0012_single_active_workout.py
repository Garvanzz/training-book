"""Allow at most one resumable workout per user.

Revision ID: 20260805_0012
Revises: 20260805_0011
Create Date: 2026-08-05
"""

from alembic import op

revision = "20260805_0012"
down_revision = "20260805_0011"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # The API resumes the existing session.  This partial unique index makes
    # the same promise safe when two devices request a start concurrently.
    # Earlier builds could create more than one in-progress session.  Keep the
    # newest one resumable and close older duplicates without deleting their
    # already logged sets, otherwise the unique index would fail to install.
    op.execute(
        """
        WITH ranked AS (
            SELECT id,
                   ROW_NUMBER() OVER (
                       PARTITION BY user_id
                       ORDER BY started_at DESC, id DESC
                   ) AS row_no
            FROM workout_sessions
            WHERE status = 'in_progress' AND deleted_at IS NULL
        )
        UPDATE workout_sessions AS ws
        SET status = 'abandoned', ended_at = COALESCE(ws.ended_at, NOW())
        FROM ranked
        WHERE ws.id = ranked.id AND ranked.row_no > 1
        """
    )
    op.execute(
        """
        CREATE UNIQUE INDEX workout_sessions_one_active_per_user_idx
        ON workout_sessions (user_id)
        WHERE status = 'in_progress' AND deleted_at IS NULL
        """
    )


def downgrade() -> None:
    op.execute("DROP INDEX workout_sessions_one_active_per_user_idx")
