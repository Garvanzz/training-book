from __future__ import annotations

from logging.config import fileConfig
from os import getenv

from alembic import context
from sqlalchemy import engine_from_config, pool

from app.core.config import get_settings

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)


def sync_database_url() -> str:
    """Use psycopg for Alembic even though the application uses asyncpg."""
    settings = get_settings()
    configured = (
        getenv("MIGRATION_DATABASE_URL")
        or getenv("DATABASE_URL")
        or settings.migration_database_url
        or settings.database_url
    )
    return configured.replace("postgresql+asyncpg://", "postgresql+psycopg://")


def run_migrations_offline() -> None:
    url = sync_database_url()
    context.configure(url=url, literal_binds=True, dialect_opts={"paramstyle": "named"})

    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    config.set_main_option("sqlalchemy.url", sync_database_url())
    section = config.get_section(config.config_ini_section) or {}
    connectable = engine_from_config(section, prefix="sqlalchemy.", poolclass=pool.NullPool)

    with connectable.connect() as connection:
        context.configure(connection=connection)

        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
