"""Restrict the API role to the tables and operations implemented by the API.

Revision ID: 20260804_0004
Revises: 20260804_0003
Create Date: 2026-08-04
"""

from alembic import op

revision = "20260804_0004"
down_revision = "20260804_0003"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # The application uses a login role distinct from the migration/table-owner
    # role.  Start from no object privileges, then grant only what existing
    # routes need.  RLS remains the row-level control for personal tables.
    op.execute(
        """
        REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM training_book_app;
        REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM training_book_app;
        REVOKE CREATE ON SCHEMA public FROM training_book_app;
        REVOKE CREATE ON SCHEMA app FROM training_book_app;

        GRANT USAGE ON SCHEMA public, app TO training_book_app;

        -- Authentication and first-owner bootstrap.
        GRANT SELECT (id, email, password_hash, is_active, is_owner, deleted_at)
            ON users TO training_book_app;
        GRANT INSERT (id, email, password_hash, is_active, is_owner)
            ON users TO training_book_app;
        GRANT INSERT (user_id, display_name) ON profiles TO training_book_app;
        GRANT INSERT, UPDATE ON device_sessions TO training_book_app;
        GRANT INSERT ON audit_logs TO training_book_app;

        -- Owner-maintained public exercise library.
        GRANT SELECT ON taxonomy_terms TO training_book_app;
        GRANT SELECT, INSERT, UPDATE ON exercises TO training_book_app;
        GRANT SELECT, INSERT, UPDATE ON exercise_versions TO training_book_app;
        GRANT SELECT, INSERT ON exercise_terms TO training_book_app;
        GRANT SELECT, INSERT, UPDATE ON exercise_media TO training_book_app;
        GRANT SELECT, INSERT ON library_releases, library_release_items TO training_book_app;

        -- User-owned plan and workout data. RLS policies restrict rows.
        GRANT SELECT, INSERT ON plans, plan_versions, session_templates, stage_blocks,
            exercise_slots, prescriptions TO training_book_app;
        GRANT SELECT, INSERT, UPDATE ON workout_sessions, set_logs TO training_book_app;
        GRANT SELECT, INSERT ON workout_items TO training_book_app;
        GRANT INSERT ON progression_suggestions TO training_book_app;
        GRANT SELECT, INSERT, UPDATE ON sync_operations TO training_book_app;
        GRANT USAGE ON SEQUENCE sync_operations_server_cursor_seq TO training_book_app;

        GRANT EXECUTE ON FUNCTION app.find_refresh_session(uuid, text, timestamptz)
            TO training_book_app;
        """
    )


def downgrade() -> None:
    raise RuntimeError(
        "This permission hardening migration is intentionally forward-only. "
        "Grant an explicitly reviewed privilege in a new migration if a new route requires it."
    )
