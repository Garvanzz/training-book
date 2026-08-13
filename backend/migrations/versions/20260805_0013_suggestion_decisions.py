"""Allow the API role to update progression-suggestion decisions.

Revision ID: 20260805_0013
Revises: 20260805_0012
Create Date: 2026-08-05
"""

from alembic import op

revision = "20260805_0013"
down_revision = "20260805_0012"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # RLS keeps the update scoped to the owning user; only the decision and
    # decided_at columns are written.
    op.execute("GRANT UPDATE (decision, decided_at) ON progression_suggestions TO training_book_app;")


def downgrade() -> None:
    raise RuntimeError("Suggestion-decision permissions are forward-only.")
