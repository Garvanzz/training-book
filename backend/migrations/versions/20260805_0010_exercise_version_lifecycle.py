"""Permit immutable published exercise revisions and draft cleanup.

Revision ID: 20260805_0010
Revises: 20260804_0009
Create Date: 2026-08-05
"""

from alembic import op

revision = "20260805_0010"
down_revision = "20260804_0009"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # A draft copied from the published version initially has the same content
    # hash.  It is an integrity fingerprint, not an identifier, so versions
    # must be allowed to share it.
    op.execute(
        "ALTER TABLE exercise_versions "
        "DROP CONSTRAINT IF EXISTS exercise_versions_exercise_id_content_hash_key;"
    )

    # Versioned records may intentionally refer to one immutable object.  This
    # lets a new draft retain released media until the owner changes it.  The
    # delete route checks references before ever deleting a local file.
    op.execute("ALTER TABLE exercise_media DROP CONSTRAINT IF EXISTS exercise_media_object_key_key;")
    op.execute("CREATE INDEX IF NOT EXISTS exercise_media_object_key_idx ON exercise_media (object_key);")
    op.execute(
        "CREATE INDEX IF NOT EXISTS exercise_media_preview_object_key_idx "
        "ON exercise_media (preview_object_key) WHERE preview_object_key IS NOT NULL;"
    )

    # An action can have one editing branch at a time.  Besides a clearer
    # product rule, this makes publishing and local-media cleanup unambiguous.
    op.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS exercise_versions_one_draft_per_exercise_idx "
        "ON exercise_versions (exercise_id) WHERE status = 'draft';"
    )

    # Least privilege: lifecycle routes only need deletes for the three tables
    # involved in deleting a never-published draft or a draft attachment.
    op.execute("GRANT DELETE ON exercises, exercise_versions, exercise_media TO training_book_app;")


def downgrade() -> None:
    raise RuntimeError("Exercise-version lifecycle changes are forward-only.")
