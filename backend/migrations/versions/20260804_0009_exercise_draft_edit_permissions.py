"""Allow an owner to replace taxonomy tags on an editable exercise draft.

Revision ID: 20260804_0009
Revises: 20260804_0008
Create Date: 2026-08-04
"""

from alembic import op

revision = "20260804_0009"
down_revision = "20260804_0008"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("GRANT DELETE ON exercise_terms TO training_book_app;")


def downgrade() -> None:
    raise RuntimeError("Exercise-draft permission changes are forward-only.")
