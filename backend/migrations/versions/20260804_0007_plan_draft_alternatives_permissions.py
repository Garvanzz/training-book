"""Allow plan-draft cloning to preserve approved slot alternatives.

Revision ID: 20260804_0007
Revises: 20260804_0006
Create Date: 2026-08-04
"""

from alembic import op

revision = "20260804_0007"
down_revision = "20260804_0006"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("GRANT SELECT, INSERT ON slot_alternatives TO training_book_app;")


def downgrade() -> None:
    raise RuntimeError("Plan-version permissions are forward-only.")
