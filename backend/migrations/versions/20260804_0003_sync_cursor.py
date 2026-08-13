"""Make the sync journal cursor database-issued and immutable.

Revision ID: 20260804_0003
Revises: 20260804_0002
Create Date: 2026-08-04
"""

from alembic import op

revision = "20260804_0003"
down_revision = "20260804_0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE SEQUENCE IF NOT EXISTS public.sync_operations_server_cursor_seq
            AS bigint
            MINVALUE 1
            START WITH 1;

        DO $$
        DECLARE
            current_max bigint;
        BEGIN
            SELECT max(server_cursor) INTO current_max FROM public.sync_operations;
            IF current_max IS NULL THEN
                PERFORM setval('public.sync_operations_server_cursor_seq', 1, false);
            ELSE
                PERFORM setval('public.sync_operations_server_cursor_seq', current_max, true);
            END IF;
        END $$;

        ALTER SEQUENCE public.sync_operations_server_cursor_seq
            OWNED BY public.sync_operations.server_cursor;

        ALTER TABLE public.sync_operations
            ALTER COLUMN server_cursor
            SET DEFAULT nextval('public.sync_operations_server_cursor_seq'::regclass);

        ALTER TABLE public.sync_operations
            ADD CONSTRAINT sync_operations_user_server_cursor_key
            UNIQUE (user_id, server_cursor);

        GRANT USAGE, SELECT ON SEQUENCE public.sync_operations_server_cursor_seq
            TO training_book_app;
        """
    )


def downgrade() -> None:
    # Do not remove historical cursors; a forward migration should retire this
    # journal if its protocol ever changes.
    raise RuntimeError("Sync cursors are part of immutable client history; use a forward migration instead.")
