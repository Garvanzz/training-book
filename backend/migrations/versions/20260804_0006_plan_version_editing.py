"""Add optimistic revisions for editable plan drafts.

Revision ID: 20260804_0006
Revises: 20260804_0005
Create Date: 2026-08-04
"""

from alembic import op

revision = "20260804_0006"
down_revision = "20260804_0005"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        ALTER TABLE plan_versions
            ADD COLUMN revision bigint NOT NULL DEFAULT 1,
            ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();

        -- A plan version is edited by replacing its child graph, then made
        -- immutable by publishing it. These are the only additional writes
        -- the API role needs for that flow.
        GRANT UPDATE ON plans, plan_versions TO training_book_app;
        GRANT DELETE ON session_templates TO training_book_app;
        """
    )


def downgrade() -> None:
    raise RuntimeError("Plan-version history is forward-only; create a new migration to retire it.")
