from __future__ import annotations

import asyncio
import json
from pathlib import Path
from uuid import NAMESPACE_URL, uuid4, uuid5

from sqlalchemy import text

from app.api.routes.library import (
    _current_snapshot_hash,
    _lock_library_releases,
)
from app.db.session import system_transaction

_CONTENT_DIR = Path(__file__).resolve().parents[3] / "content" / "exercises"
_ID_NAMESPACE = "https://training-book.local/exercises/"


def _external_id(external_key: str) -> str:
    return str(uuid5(NAMESPACE_URL, _ID_NAMESPACE + external_key))


async def import_exercises() -> int:
    """Import system exercises as published actions plus one library release.

    Stable ids are derived from ``external_key``, so re-running the command is
    idempotent: an already-imported action is skipped, and only new actions
    contribute to the new release.
    """

    files = sorted(_CONTENT_DIR.glob("*.json"))
    if not files:
        raise ValueError(f"No exercise files found in {_CONTENT_DIR}")

    imported: list[tuple[str, int]] = []
    async with system_transaction() as session:
        # exercise_versions requires a content author; system imports attribute
        # to the first active owner account, which bootstrap_owner creates.
        author_user_id = await session.scalar(
            text(
                """
                SELECT id FROM users
                WHERE is_owner = true AND is_active = true AND deleted_at IS NULL
                ORDER BY id
                LIMIT 1
                """
            )
        )
        if author_user_id is None:
            raise ValueError("No active owner account: run bootstrap_owner before import_exercises.")

        for path in files:
            payload = json.loads(path.read_text(encoding="utf-8"))
            external_key = str(payload["external_key"])
            exercise_id = _external_id(external_key)
            exists = await session.scalar(
                text("SELECT EXISTS (SELECT 1 FROM exercises WHERE id = :id)"),
                {"id": exercise_id},
            )
            if exists is True:
                print(f"skip {external_key} (already imported)")
                continue

            version_id = uuid4()
            await session.execute(
                text(
                    """
                    INSERT INTO exercises (
                        id, source, status, current_published_version
                    ) VALUES (:id, 'system', 'published', 1)
                    """
                ),
                {"id": exercise_id},
            )
            await session.execute(
                text(
                    """
                    INSERT INTO exercise_versions (
                        id, exercise_id, version_no, status, name_zh, name_en,
                        summary, recording_mode, instructions_json, cues_json,
                        mistakes_json, safety_json, content_hash, author_user_id,
                        change_summary
                    ) VALUES (
                        :id, :exercise_id, 1, 'published', :name_zh, :name_en,
                        :summary, :recording_mode, CAST(:instructions AS jsonb),
                        CAST(:cues AS jsonb), CAST(:mistakes AS jsonb),
                        CAST(:safety AS jsonb), :content_hash, :author_user_id,
                        :change_summary
                    )
                    """
                ),
                {
                    "id": version_id,
                    "exercise_id": exercise_id,
                    "name_zh": payload["name_zh"],
                    "name_en": payload.get("name_en"),
                    "summary": payload["summary"],
                    "recording_mode": payload["recording_mode"],
                    "instructions": json.dumps(payload["instructions"], ensure_ascii=False),
                    "cues": json.dumps(payload["cues"], ensure_ascii=False),
                    "mistakes": json.dumps(payload["mistakes"], ensure_ascii=False),
                    "safety": json.dumps(payload["safety_notes"], ensure_ascii=False),
                    "content_hash": _version_content_hash(payload),
                    "author_user_id": author_user_id,
                    "change_summary": "system import",
                },
            )
            await _insert_tags(session, version_id, payload.get("tags") or {})
            imported.append((exercise_id, version_id))
            print(f"imported {external_key}")

        if not imported:
            return 0

        await _lock_library_releases(session)
        release_no = int(
            await session.scalar(text("SELECT COALESCE(MAX(release_no), 0) + 1 FROM library_releases"))
        )
        release_id = uuid4()
        manifest_hash = await _current_snapshot_hash(session)
        await session.execute(
            text(
                """
                INSERT INTO library_releases (
                    id, release_no, status, manifest_hash, min_client_schema,
                    published_by_user_id, published_at
                ) VALUES (:id, :release_no, 'published', :manifest_hash, 1, NULL, now())
                """
            ),
            {"id": release_id, "release_no": release_no, "manifest_hash": manifest_hash},
        )
        for exercise_id, version_id in imported:
            await session.execute(
                text(
                    "INSERT INTO library_release_items (release_id, exercise_version_id) VALUES (:release_id, :version_id)"
                ),
                {"release_id": release_id, "version_id": version_id},
            )
        print(f"published release {release_no} with {len(imported)} actions")

    return len(imported)


def _version_content_hash(payload: dict[str, object]) -> str:
    """Stable content hash matching the client library checksum format."""

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


async def _insert_tags(session, version_id, tags: dict[str, object]) -> None:
    for dimension, codes in tags.items():
        if not isinstance(codes, list):
            continue
        for code in codes:
            term_id = await session.scalar(
                text(
                    """
                    SELECT id FROM taxonomy_terms
                    WHERE dimension = :dimension AND code = :code AND is_active = true
                    """
                ),
                {"dimension": dimension, "code": str(code)},
            )
            if term_id is None:
                raise ValueError(f"Unknown taxonomy term {dimension}:{code}")
            await session.execute(
                text(
                    """
                    INSERT INTO exercise_terms (exercise_version_id, term_id)
                    VALUES (:version_id, :term_id)
                    ON CONFLICT DO NOTHING
                    """
                ),
                {"version_id": version_id, "term_id": term_id},
            )


def main() -> None:
    count = asyncio.run(import_exercises())
    print(f"Done. {count} new actions imported.")


if __name__ == "__main__":
    main()
