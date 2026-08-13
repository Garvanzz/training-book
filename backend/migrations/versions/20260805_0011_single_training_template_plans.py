"""Reset legacy multi-session plans and enforce one template per plan version.

Revision ID: 20260805_0011
Revises: 20260805_0010
Create Date: 2026-08-05

The product model changed from a weekly plan containing many training days to
one plan being one executable training template.  Existing plan/workout data
was explicitly declared disposable for this local-first product reset.  We
leave the relational ``session_templates`` table in place as an internal
container because immutable workout rows still reference it, while enforcing a
single container for every new plan version.
"""

from alembic import op

revision = "20260805_0011"
down_revision = "20260805_0010"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        -- The user chose a clean product-model reset.  Clear only records
        -- whose meaning depended on the former multi-session plan model.
        -- Delete in dependency order; plan_versions then cascades its stage,
        -- slot, prescription and alternative children.
        DELETE FROM sync_operations
        WHERE entity_type IN (
            'plan', 'plan_version', 'session_template', 'stage_block',
            'exercise_slot', 'workout', 'workout_session', 'workout_item',
            'set_log'
        );
        DELETE FROM progression_suggestions;
        DELETE FROM workout_sessions;
        DELETE FROM plan_versions;
        DELETE FROM plans;

        -- ``session_templates`` is now storage-only.  This database invariant
        -- prevents future API regressions from recreating training-day lists.
        CREATE UNIQUE INDEX session_templates_one_per_plan_version_idx
            ON session_templates (plan_version_id);
        """
    )


def downgrade() -> None:
    raise RuntimeError("The single-training-template plan reset is forward-only.")
