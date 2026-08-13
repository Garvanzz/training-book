"""Grant the API role the privileges for data export and account deletion.

Export reads every user-owned table through RLS; account deletion soft-deletes
the users row and relies on revoked device_sessions to end access.
"""

from alembic import op

revision = "20260813_0014"
down_revision = "20260805_0013"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        GRANT SELECT ON profiles, user_settings, user_equipment TO training_book_app;
        GRANT SELECT ON progression_suggestions TO training_book_app;
        GRANT UPDATE (deleted_at, updated_at) ON users TO training_book_app;
        """
    )


def downgrade() -> None:
    raise RuntimeError(
        "Permission grants are intentionally forward-only. "
        "REVOKE in a new migration after an explicit review if a route disappears."
    )
