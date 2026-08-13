"""Allow the API role to atomically compare and rotate refresh-token state.

Revision ID: 20260804_0005
Revises: 20260804_0004
Create Date: 2026-08-04
"""

from alembic import op

revision = "20260804_0005"
down_revision = "20260804_0004"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # UPDATE predicates and RETURNING require SELECT on the referenced columns.
    # These are hashes/identifiers only; raw refresh tokens are never stored.
    op.execute(
        """
        GRANT SELECT (id, user_id, device_id, refresh_token_hash, refresh_expires_at, revoked_at)
            ON device_sessions TO training_book_app;
        """
    )


def downgrade() -> None:
    raise RuntimeError("Refresh-token permission changes are forward-only.")
