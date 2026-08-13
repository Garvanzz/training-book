"""Add a narrowly scoped security-definer lookup for refresh-token redemption.

Revision ID: 20260804_0002
Revises: 20260803_0001
Create Date: 2026-08-04
"""

from alembic import op

revision = "20260804_0002"
down_revision = "20260803_0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE OR REPLACE FUNCTION app.find_refresh_session(
            p_device_id uuid,
            p_refresh_token_hash text,
            p_now timestamptz
        )
        RETURNS uuid
        LANGUAGE sql
        SECURITY DEFINER
        SET search_path = pg_catalog, public
        AS $$
            SELECT ds.user_id
            FROM public.device_sessions AS ds
            JOIN public.users AS u ON u.id = ds.user_id
            WHERE ds.device_id = p_device_id
              AND ds.refresh_token_hash = p_refresh_token_hash
              AND ds.refresh_expires_at > p_now
              AND ds.revoked_at IS NULL
              AND u.is_active = true
              AND u.deleted_at IS NULL
            LIMIT 1;
        $$;

        REVOKE ALL ON FUNCTION app.find_refresh_session(uuid, text, timestamptz) FROM PUBLIC;
        GRANT EXECUTE ON FUNCTION app.find_refresh_session(uuid, text, timestamptz) TO training_book_app;
        """
    )


def downgrade() -> None:
    op.execute("DROP FUNCTION app.find_refresh_session(uuid, text, timestamptz)")
