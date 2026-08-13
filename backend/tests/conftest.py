"""Integration-test setup: run against the developer database from backend/.env.

The suite reuses ``training_book`` instead of creating a throwaway database
(the migration role has no CREATEDB privilege).  Alembic upgrade and all seed
inserts are idempotent, so re-running the suite is safe.  Tests create rows
under random user ids; a small residue of test users accumulates in the local
database by design and is harmless.  ponytail: revisit with a real test
database when CI needs isolation.
"""

from __future__ import annotations

import json
import os
import uuid
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
_EXERCISE_ID_NAMESPACE = "https://training-book.local/exercises/"


def _env_value(key: str) -> str:
    for line in (BACKEND_DIR / ".env").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        if name.strip() == key:
            return value.strip()
    raise RuntimeError(f"{key} is missing from backend/.env")


# Must run before any app.* import: Settings and the engine builders are
# lru_cached, and the pytest working directory must not matter for .env.
os.environ["DATABASE_URL"] = _env_value("DATABASE_URL")
os.environ["MIGRATION_DATABASE_URL"] = _env_value("MIGRATION_DATABASE_URL")

import psycopg
import pytest


def _owner_connection() -> psycopg.Connection:
    import re

    url = re.sub(r"postgresql\+[a-z]+://", "postgresql://", _env_value("MIGRATION_DATABASE_URL"))
    return psycopg.connect(url, autocommit=True)


def _exercise_id(external_key: str) -> uuid.UUID:
    return uuid.uuid5(uuid.NAMESPACE_URL, _EXERCISE_ID_NAMESPACE + external_key)


def _migrate() -> None:
    from alembic import command
    from alembic.config import Config

    config = Config(str(BACKEND_DIR / "alembic.ini"))
    config.set_main_option("script_location", str(BACKEND_DIR / "migrations"))
    command.upgrade(config, "head")


def _seed_taxonomy(conn: psycopg.Connection) -> None:
    payload = json.loads(
        (BACKEND_DIR.parent / "content" / "seed" / "taxonomy.zh-CN.json").read_text(encoding="utf-8")
    )
    for term in payload["terms"]:
        conn.execute(
            """
            INSERT INTO taxonomy_terms (id, dimension, code, name_zh, sort_order, is_active)
            VALUES (%s, %s, %s, %s, %s, true)
            ON CONFLICT (dimension, code) DO UPDATE SET
                name_zh = EXCLUDED.name_zh,
                sort_order = EXCLUDED.sort_order,
                is_active = true
            """,
            (
                uuid.uuid5(uuid.NAMESPACE_URL, f"training-book:taxonomy:{term['dimension']}:{term['code']}"),
                term["dimension"],
                term["code"],
                term["name_zh"],
                int(term.get("sort_order", 0)),
            ),
        )


def _seed_exercises(conn: psycopg.Connection) -> list[uuid.UUID]:
    """Insert the first two content actions as published exercises.

    Idempotent: stable ids are derived from ``external_key`` and rows that
    already exist are left untouched.  Returns the exercise ids; tests use
    them in plan slots.
    """

    seed_author_id = uuid.uuid5(uuid.NAMESPACE_URL, "training-book:test-seed-author")
    conn.execute(
        """
        INSERT INTO users (id, email, password_hash, is_active, is_owner)
        VALUES (%s, %s, 'not-a-real-hash', true, false)
        ON CONFLICT (id) DO NOTHING
        """,
        (seed_author_id, "test-seed-author@example.com"),
    )

    exercise_ids: list[uuid.UUID] = []
    files = sorted((BACKEND_DIR.parent / "content" / "exercises").glob("*.json"))[:2]
    # exercises.current_published_version is a deferrable FK: the exercise row
    # and its published version must land in the same transaction.
    with conn.transaction():
        for path in files:
            payload = json.loads(path.read_text(encoding="utf-8"))
            exercise_id = _exercise_id(str(payload["external_key"]))
            version_id = uuid.uuid4()
            conn.execute(
                """
                INSERT INTO exercises (id, source, status, current_published_version)
                VALUES (%s, 'system', 'published', 1)
                ON CONFLICT (id) DO NOTHING
                """,
                (exercise_id,),
            )
            conn.execute(
                """
                INSERT INTO exercise_versions (
                    id, exercise_id, version_no, status, name_zh, name_en,
                    summary, recording_mode, instructions_json, cues_json,
                    mistakes_json, safety_json, content_hash, author_user_id,
                    change_summary
                ) VALUES (
                    %s, %s, 1, 'published', %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
                )
                ON CONFLICT (exercise_id, version_no) DO NOTHING
                """,
                (
                    version_id,
                    exercise_id,
                    payload["name_zh"],
                    payload.get("name_en"),
                    payload["summary"],
                    payload["recording_mode"],
                    json.dumps(payload["instructions"], ensure_ascii=False),
                    json.dumps(payload["cues"], ensure_ascii=False),
                    json.dumps(payload["mistakes"], ensure_ascii=False),
                    json.dumps(payload["safety_notes"], ensure_ascii=False),
                    _version_content_hash(payload),
                    seed_author_id,
                    "test seed import",
                ),
            )
            exercise_ids.append(exercise_id)
    return exercise_ids


def _version_content_hash(payload: dict) -> str:
    import hashlib

    stable = json.dumps(
        {
            "name_zh": payload["name_zh"],
            "name_en": payload.get("name_en"),
            "summary": payload["summary"],
            "recording_mode": payload["recording_mode"],
            "instructions": payload["instructions"],
            "cues": payload["cues"],
            "mistakes": payload["mistakes"],
            "safety_notes": payload["safety_notes"],
        },
        ensure_ascii=False,
        sort_keys=True,
    )
    return hashlib.sha256(stable.encode("utf-8")).hexdigest()


@pytest.fixture(scope="session")
def seeded_exercise_ids() -> list[uuid.UUID]:
    _migrate()
    with _owner_connection() as conn:
        _seed_taxonomy(conn)
        return _seed_exercises(conn)


@pytest.fixture(autouse=True)
async def _dispose_database_after_test() -> None:
    """Close the async connection pool after each async test.

    pytest-asyncio runs one event loop per test function; pooled asyncpg
    connections cannot survive into the next loop.  Disposing rebuilds the
    lru-cached engine lazily on the next use.
    """
    yield
    from app.db.session import dispose_database

    await dispose_database()
