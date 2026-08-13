"""Grant the API role the columns read by the login session upsert.

Revision ID: 20260804_0008
Revises: 20260804_0007
Create Date: 2026-08-04
"""

from alembic import op

revision = "20260804_0008"
down_revision = "20260804_0007"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # PostgreSQL's INSERT .. ON CONFLICT DO UPDATE checks SELECT privileges for
    # columns it reads while detecting and updating the conflicting row.  Keep
    # this column-scoped: device sessions must not become broadly readable.
    op.execute(
        """
        GRANT SELECT (
            device_name,
            platform,
            offline_lease_expires_at,
            last_online_at,
            updated_at
        ) ON device_sessions TO training_book_app;
        """
    )


def downgrade() -> None:
    raise RuntimeError("Device-session permission changes are forward-only.")
