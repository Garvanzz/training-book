from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from functools import lru_cache
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app.core.config import get_settings


@lru_cache
def build_engine() -> AsyncEngine:
    return create_async_engine(get_settings().database_url, pool_pre_ping=True)


@lru_cache
def build_session_factory() -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(build_engine(), expire_on_commit=False)


async def dispose_database() -> None:
    """Close pooled connections during application shutdown and isolated tests."""
    if build_engine.cache_info().currsize:
        await build_engine().dispose()
    build_session_factory.cache_clear()
    build_engine.cache_clear()


@asynccontextmanager
async def system_transaction() -> AsyncIterator[AsyncSession]:
    """Open a backend-only transaction for login and content administration."""
    async with build_session_factory()() as session, session.begin():
        yield session


@asynccontextmanager
async def user_transaction(user_id: UUID) -> AsyncIterator[AsyncSession]:
    """Open one transaction with PostgreSQL RLS scoped to the authenticated user."""
    session_factory = build_session_factory()
    async with session_factory() as session, session.begin():
        await session.execute(
            text("SELECT set_config('app.user_id', :user_id, true)"),
            {"user_id": str(user_id)},
        )
        yield session
