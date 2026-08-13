"""Create the Training Book initial schema.

Revision ID: 20260803_0001
Revises:
Create Date: 2026-08-03
"""

from pathlib import Path

from alembic import op

revision = "20260803_0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    sql_path = Path(__file__).parents[1] / "001_initial_schema.sql"
    op.execute(sql_path.read_text(encoding="utf-8"))


def downgrade() -> None:
    raise RuntimeError(
        "The initial schema contains personal training data and has no automatic downgrade. "
        "Restore a backup or create a forward migration instead."
    )
