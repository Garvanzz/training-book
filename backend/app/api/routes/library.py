from __future__ import annotations

import json
import re
from collections import defaultdict
from hashlib import sha256
from pathlib import Path
from typing import Annotated
from uuid import UUID, uuid4

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    HTTPException,
    Query,
    Response,
    UploadFile,
    status,
)
from sqlalchemy import text

from app.api.dependencies import Principal, require_owner
from app.api.schemas import (
    ExerciseDetailResponse,
    ExerciseDraftRequest,
    ExerciseDraftResponse,
    ExerciseMediaResponse,
    ExerciseSummaryResponse,
    LibraryDeltaResponse,
    LibraryManifestResponse,
    LibraryReleaseDeltaResponse,
    LibraryReleaseItemResponse,
    LibrarySnapshotResponse,
    MarkMediaReadyRequest,
    PublishExerciseResponse,
    TaxonomyTermResponse,
)
from app.core.config import get_settings
from app.db.session import system_transaction

router = APIRouter(prefix="/v1/library", tags=["library"])

_LIBRARY_RELEASE_LOCK = 734205021
_SAFE_EXTENSION = re.compile(r"^\.[a-z0-9]{1,10}$")
_MEDIA_MIME_BY_EXTENSION = {
    ".mp4": "video/mp4",
    ".m4v": "video/x-m4v",
    ".mov": "video/quicktime",
    ".webm": "video/webm",
    ".avi": "video/x-msvideo",
    ".mkv": "video/x-matroska",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
}


def _local_media_path(object_key: str) -> Path | None:
    """Return a local-media path only when the stored key is contained safely.

    Database records can also point at the future object-storage adapter, so a
    delete operation must never treat an arbitrary object key as a filesystem
    path.  In particular, this makes old or malformed records harmless.
    """

    if not object_key.startswith("local/"):
        return None
    root = get_settings().local_media_root.resolve()
    candidate = (root / object_key).resolve()
    try:
        candidate.relative_to(root)
    except ValueError:
        return None
    return candidate


async def _lock_media_object_keys(session, object_keys: list[str]) -> None:
    """Serialize deletion and version cloning for a physical media object."""

    for object_key in sorted(set(object_keys)):
        await session.execute(
            text("SELECT pg_advisory_xact_lock(hashtextextended(:object_key, 0))"),
            {"object_key": object_key},
        )


async def _delete_unreferenced_local_files(session, object_keys: list[str]) -> None:
    """Best-effort cleanup, guarded by a database reference check and lock.

    This deliberately ignores filesystem errors.  A failed cleanup leaves an
    orphan that can be retried later; raising after database rows are removed
    risks reporting a failed edit even though the transaction is valid.  It
    never deletes an object while a media row still references it.
    """

    for object_key in sorted(set(filter(None, object_keys))):
        path = _local_media_path(object_key)
        if path is None:
            continue
        references = int(
            await session.scalar(
                text(
                    """
                    SELECT count(*)
                    FROM exercise_media
                    WHERE object_key = :object_key OR preview_object_key = :object_key
                    """
                ),
                {"object_key": object_key},
            )
            or 0
        )
        if references != 0:
            continue
        try:
            path.unlink(missing_ok=True)
        except OSError:
            # Do not make an API caller retry a database deletion solely due
            # to an antivirus/file-handle race on Windows.
            continue


def _content_hash(request: ExerciseDraftRequest) -> str:
    canonical = json.dumps(
        request.model_dump(mode="json"),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return sha256(canonical.encode("utf-8")).hexdigest()


async def _resolve_tag_ids(session, tags: dict[str, list[str]]) -> list[UUID]:
    if not tags:
        return []
    if not all(tags.values()):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="Tag dimensions cannot be submitted with an empty value list.",
        )

    result = await session.execute(
        text("SELECT id, dimension, code FROM taxonomy_terms WHERE is_active = true")
    )
    lookup = {(str(row["dimension"]), str(row["code"])): row["id"] for row in result.mappings()}
    tag_ids: list[UUID] = []
    unknown_tags: list[str] = []
    for dimension, codes in tags.items():
        for code in codes:
            term_id = lookup.get((dimension, code))
            if term_id is None:
                unknown_tags.append(f"{dimension}:{code}")
            else:
                tag_ids.append(term_id)
    if unknown_tags:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail={"message": "Unknown taxonomy tag", "tags": unknown_tags},
        )
    return list(dict.fromkeys(tag_ids))


async def _lock_library_releases(session) -> None:
    """Serialize a manifest/range read with an owner publishing a release."""

    await session.execute(text("SELECT pg_advisory_xact_lock(:lock_id)"), {"lock_id": _LIBRARY_RELEASE_LOCK})


async def _latest_published_release(session) -> dict[str, object] | None:
    result = await session.execute(
        text(
            """
            SELECT id, release_no, manifest_hash, min_client_schema
            FROM library_releases
            WHERE status = 'published'
            ORDER BY release_no DESC
            LIMIT 1
            """
        )
    )
    return result.mappings().one_or_none()


async def _current_snapshot_items(session) -> list[LibraryReleaseItemResponse]:
    result = await session.execute(
        text(
            """
            SELECT e.id AS exercise_id, ev.version_no, ev.name_zh,
                   ev.recording_mode, ev.content_hash
            FROM exercises AS e
            JOIN exercise_versions AS ev
              ON ev.exercise_id = e.id
             AND ev.version_no = e.current_published_version
            WHERE e.status = 'published' AND ev.status = 'published'
            ORDER BY e.id
            """
        )
    )
    return [LibraryReleaseItemResponse.model_validate(row) for row in result.mappings()]


async def _current_snapshot_hash(session) -> str:
    """Hash the complete current library state, including published media blobs."""

    result = await session.execute(
        text(
            """
            SELECT e.id AS exercise_id, ev.version_no, ev.content_hash,
                   COALESCE(
                       array_agg(media.sha256 ORDER BY media.sha256)
                           FILTER (WHERE media.sha256 IS NOT NULL),
                       ARRAY[]::text[]
                   ) AS media_hashes
            FROM exercises AS e
            JOIN exercise_versions AS ev
              ON ev.exercise_id = e.id
             AND ev.version_no = e.current_published_version
            LEFT JOIN exercise_media AS media
              ON media.exercise_version_id = ev.id
             AND media.status = 'published'
            WHERE e.status = 'published' AND ev.status = 'published'
            GROUP BY e.id, ev.version_no, ev.content_hash
            ORDER BY e.id
            """
        )
    )
    material = [
        {
            "exercise_id": str(row["exercise_id"]),
            "version_no": int(row["version_no"]),
            "content_hash": str(row["content_hash"]),
            "media_hashes": list(row["media_hashes"]),
        }
        for row in result.mappings()
    ]
    canonical = json.dumps(material, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return sha256(canonical.encode("utf-8")).hexdigest()


async def _has_complete_delta_range(session, after_release: int, through_release: int) -> bool:
    """Only advertise a delta when every intermediate published release exists."""

    if after_release < 1 or after_release >= through_release:
        return False
    base_exists = await session.scalar(
        text(
            """
            SELECT EXISTS (
                SELECT 1 FROM library_releases
                WHERE release_no = :after_release AND status = 'published'
            )
            """
        ),
        {"after_release": after_release},
    )
    if base_exists is not True:
        return False
    count = int(
        await session.scalar(
            text(
                """
                SELECT count(*)
                FROM library_releases
                WHERE release_no > :after_release
                  AND release_no <= :through_release
                  AND status = 'published'
                """
            ),
            {"after_release": after_release, "through_release": through_release},
        )
        or 0
    )
    return count == through_release - after_release


@router.get("/taxonomy", response_model=list[TaxonomyTermResponse])
async def list_taxonomy() -> list[TaxonomyTermResponse]:
    async with system_transaction() as session:
        result = await session.execute(
            text(
                """
                SELECT id, dimension, code, name_zh, sort_order
                FROM taxonomy_terms
                WHERE is_active = true
                ORDER BY dimension, sort_order, code
                """
            )
        )
        return [TaxonomyTermResponse.model_validate(row) for row in result.mappings()]


@router.get("/manifest", response_model=LibraryManifestResponse)
async def get_library_manifest(
    release: int = Query(default=0, ge=0),
    manifest_hash: str | None = Query(default=None, pattern=r"^[a-f0-9]{64}$"),
) -> LibraryManifestResponse:
    async with system_transaction() as session:
        await _lock_library_releases(session)
        latest = await _latest_published_release(session)
        if latest is None:
            return LibraryManifestResponse(
                release_no=0,
                manifest_hash="0" * 64,
                min_client_schema=1,
                change="none" if release == 0 else "snapshot",
                snapshot_release=0 if release > 0 else None,
            )

        latest_release = int(latest["release_no"])
        current_hash = await _current_snapshot_hash(session)
        if release == latest_release and (manifest_hash is None or manifest_hash == current_hash):
            change = "none"
        elif release > latest_release or release == 0:
            change = "snapshot"
        else:
            change = "delta" if await _has_complete_delta_range(session, release, latest_release) else "snapshot"

    return LibraryManifestResponse(
        release_no=latest_release,
        # This is calculated from the immutable current exercise versions and
        # published media, not merely the final changed item in a release.
        manifest_hash=current_hash,
        min_client_schema=int(latest["min_client_schema"]),
        change=change,
        delta_after_release=release if change == "delta" else None,
        delta_through_release=latest_release if change == "delta" else None,
        snapshot_release=latest_release if change == "snapshot" else None,
        download_url=None,
    )


@router.get("/delta", response_model=LibraryDeltaResponse)
async def get_library_delta(
    after_release: int = Query(ge=0),
    through_release: int = Query(ge=1),
    limit: int = Query(default=20, ge=1, le=100),
) -> LibraryDeltaResponse:
    """Read complete, release-atomic changes for a manifest-pinned range.

    ``through_release`` must be copied from ``/manifest``.  New releases may
    be published while a client is paging, but cannot enter this range.
    """

    if after_release > through_release:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="after_release must not be greater than through_release.",
        )

    async with system_transaction() as session:
        await _lock_library_releases(session)
        latest = await _latest_published_release(session)
        if latest is None or through_release > int(latest["release_no"]):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="The requested release target is unavailable; refresh the manifest.",
            )
        target = (
            await session.execute(
                text(
                    """
                    SELECT release_no, manifest_hash, min_client_schema
                    FROM library_releases
                    WHERE release_no = :release_no AND status = 'published'
                    """
                ),
                {"release_no": through_release},
            )
        ).mappings().one_or_none()
        if target is None:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="The requested release target is unavailable; refresh the manifest.",
            )
        if after_release == through_release:
            target_hash = (
                await _current_snapshot_hash(session)
                if through_release == int(latest["release_no"])
                else str(target["manifest_hash"])
            )
            return LibraryDeltaResponse(
                after_release=after_release,
                through_release=through_release,
                next_after_release=after_release,
                manifest_hash=target_hash,
                min_client_schema=int(target["min_client_schema"]),
                releases=[],
                has_more=False,
            )
        if not await _has_complete_delta_range(session, after_release, through_release):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="The requested release range is incomplete; fetch a snapshot instead.",
            )

        headers = list(
            (
                await session.execute(
                    text(
                        """
                        SELECT id, release_no, manifest_hash, min_client_schema
                        FROM library_releases
                        WHERE release_no > :after_release
                          AND release_no <= :through_release
                          AND status = 'published'
                        ORDER BY release_no
                        LIMIT :limit_plus_one
                        """
                    ),
                    {
                        "after_release": after_release,
                        "through_release": through_release,
                        "limit_plus_one": limit + 1,
                    },
                )
            ).mappings()
        )
        has_more = len(headers) > limit
        page = headers[:limit]
        release_ids = [row["id"] for row in page]
        item_rows = []
        if release_ids:
            item_rows = list(
                (
                    await session.execute(
                        text(
                            """
                            SELECT release.id AS release_id, exercise.id AS exercise_id, version.version_no,
                                   version.name_zh, version.recording_mode, version.content_hash
                            FROM library_releases AS release
                            JOIN library_release_items AS item ON item.release_id = release.id
                            JOIN exercise_versions AS version ON version.id = item.exercise_version_id
                            JOIN exercises AS exercise ON exercise.id = version.exercise_id
                            WHERE release.id = ANY(CAST(:release_ids AS uuid[]))
                            ORDER BY release.release_no, exercise.id, version.version_no
                            """
                        ),
                        {"release_ids": release_ids},
                    )
                ).mappings()
            )
        items_by_release: dict[UUID, list[LibraryReleaseItemResponse]] = defaultdict(list)
        for row in item_rows:
            items_by_release[row["release_id"]].append(LibraryReleaseItemResponse.model_validate(row))
        target_hash = (
            await _current_snapshot_hash(session)
            if through_release == int(latest["release_no"])
            else str(target["manifest_hash"])
        )

    releases = [
        LibraryReleaseDeltaResponse(
            release_no=int(row["release_no"]),
            manifest_hash=str(row["manifest_hash"]),
            min_client_schema=int(row["min_client_schema"]),
            items=items_by_release[row["id"]],
        )
        for row in page
    ]
    return LibraryDeltaResponse(
        after_release=after_release,
        through_release=through_release,
        next_after_release=releases[-1].release_no if releases else after_release,
        manifest_hash=target_hash,
        min_client_schema=int(target["min_client_schema"]),
        releases=releases,
        has_more=has_more,
    )


@router.get("/snapshot/{release_no}", response_model=LibrarySnapshotResponse)
async def get_library_snapshot(
    release_no: int,
) -> LibrarySnapshotResponse:
    """Return a full immutable-version snapshot for the current manifest only."""

    async with system_transaction() as session:
        await _lock_library_releases(session)
        latest = await _latest_published_release(session)
        if latest is None:
            if release_no != 0:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="The requested snapshot is unavailable; refresh the manifest.",
                )
            return LibrarySnapshotResponse(
                release_no=0,
                manifest_hash="0" * 64,
                min_client_schema=1,
                items=[],
            )
        if release_no != int(latest["release_no"]):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="The requested snapshot is no longer current; refresh the manifest.",
            )
        items = await _current_snapshot_items(session)
        manifest_hash = await _current_snapshot_hash(session)
        min_client_schema = int(latest["min_client_schema"])
    return LibrarySnapshotResponse(
        release_no=release_no,
        manifest_hash=manifest_hash,
        min_client_schema=min_client_schema,
        items=items,
    )


@router.get("/releases/{release_no}", response_model=list[LibraryReleaseItemResponse])
async def get_library_release(
    release_no: int,
) -> list[LibraryReleaseItemResponse]:
    async with system_transaction() as session:
        result = await session.execute(
            text(
                """
                SELECT exercise.id AS exercise_id, version.version_no, version.name_zh,
                       version.recording_mode, version.content_hash
                FROM library_releases AS release
                JOIN library_release_items AS item ON item.release_id = release.id
                JOIN exercise_versions AS version ON version.id = item.exercise_version_id
                JOIN exercises AS exercise ON exercise.id = version.exercise_id
                WHERE release.release_no = :release_no AND release.status = 'published'
                ORDER BY version.name_zh, exercise.id
                """
            ),
            {"release_no": release_no},
        )
        return [LibraryReleaseItemResponse.model_validate(row) for row in result.mappings()]


@router.post("/exercises", response_model=ExerciseDraftResponse, status_code=status.HTTP_201_CREATED)
async def create_exercise_draft(
    request: ExerciseDraftRequest,
    principal: Annotated[Principal, Depends(require_owner)],
) -> ExerciseDraftResponse:
    exercise_id = uuid4()
    version_id = uuid4()
    content_hash = _content_hash(request)

    async with system_transaction() as session:
        tag_ids = await _resolve_tag_ids(session, request.tags)
        await session.execute(
            text(
                """
                INSERT INTO exercises (id, source, owner_user_id, status)
                VALUES (:id, 'user', :owner_user_id, 'draft')
                """
            ),
            {"id": exercise_id, "owner_user_id": principal.user_id},
        )
        await session.execute(
            text(
                """
                INSERT INTO exercise_versions (
                    id, exercise_id, version_no, status, name_zh, name_en, summary,
                    instructions_json, cues_json, mistakes_json, safety_json, recording_mode,
                    content_hash, author_user_id, change_summary
                ) VALUES (
                    :id, :exercise_id, 1, 'draft', :name_zh, :name_en, :summary,
                    CAST(:instructions AS jsonb), CAST(:cues AS jsonb), CAST(:mistakes AS jsonb),
                    CAST(:safety_notes AS jsonb), :recording_mode, :content_hash, :author_user_id,
                    :change_summary
                )
                """
            ),
            {
                "id": version_id,
                "exercise_id": exercise_id,
                "name_zh": request.name_zh,
                "name_en": request.name_en,
                "summary": request.summary,
                "instructions": json.dumps(request.instructions, ensure_ascii=False),
                "cues": json.dumps(request.cues, ensure_ascii=False),
                "mistakes": json.dumps(request.mistakes, ensure_ascii=False),
                "safety_notes": json.dumps(request.safety_notes, ensure_ascii=False),
                "recording_mode": request.recording_mode,
                "content_hash": content_hash,
                "author_user_id": principal.user_id,
                "change_summary": request.change_summary,
            },
        )
        for term_id in tag_ids:
            await session.execute(
                text(
                    """
                    INSERT INTO exercise_terms (exercise_version_id, term_id, is_primary)
                    VALUES (:exercise_version_id, :term_id, false)
                    """
                ),
                {"exercise_version_id": version_id, "term_id": term_id},
            )
        for media in request.media:
            await session.execute(
                text(
                    """
                    INSERT INTO exercise_media (
                        id, exercise_version_id, media_type, object_key, preview_object_key, sha256,
                        duration_ms, content_type, license_type, rights_holder, alt_text_zh, status
                    ) VALUES (
                        :id, :exercise_version_id, :media_type, :object_key, :preview_object_key,
                        :sha256, :duration_ms, :content_type, :license_type, :rights_holder,
                        :alt_text_zh, 'draft'
                    )
                    """
                ),
                {"id": uuid4(), "exercise_version_id": version_id, **media.model_dump()},
            )

    return ExerciseDraftResponse(id=exercise_id, version_no=1, status="draft")


@router.get("/drafts", response_model=list[ExerciseSummaryResponse])
async def list_owner_drafts(
    principal: Annotated[Principal, Depends(require_owner)],
) -> list[ExerciseSummaryResponse]:
    """List incomplete owner content separately from the published library."""

    async with system_transaction() as session:
        result = await session.execute(
            text(
                """
                SELECT e.id, ev.version_no, ev.name_zh, ev.name_en, ev.summary, ev.recording_mode,
                       COALESCE(
                           array_agg(DISTINCT purpose_term.code)
                               FILTER (WHERE purpose_term.code IS NOT NULL),
                           ARRAY[]::text[]
                       ) AS purposes
                FROM exercises AS e
                JOIN exercise_versions AS ev ON ev.exercise_id = e.id AND ev.status = 'draft'
                LEFT JOIN exercise_terms AS et ON et.exercise_version_id = ev.id
                LEFT JOIN taxonomy_terms AS purpose_term
                  ON purpose_term.id = et.term_id AND purpose_term.dimension = 'purpose'
                WHERE e.status IN ('draft', 'published')
                  AND e.owner_user_id = :owner_user_id
                GROUP BY e.id, ev.version_no, ev.name_zh, ev.name_en, ev.summary, ev.recording_mode
                ORDER BY ev.created_at DESC, e.id
                """
            ),
            {"owner_user_id": principal.user_id},
        )
        return [ExerciseSummaryResponse.model_validate(row) for row in result.mappings()]


@router.get("/drafts/{exercise_id}/versions/{version_no}", response_model=ExerciseDetailResponse)
async def get_owner_draft(
    exercise_id: UUID,
    version_no: int,
    principal: Annotated[Principal, Depends(require_owner)],
) -> ExerciseDetailResponse:
    """Read an owner draft, including incomplete text and uploaded media."""

    async with system_transaction() as session:
        version = (
            await session.execute(
                text(
                    """
                    SELECT e.id, ev.id AS version_id, ev.version_no, ev.name_zh, ev.name_en, ev.summary,
                           ev.recording_mode, ev.instructions_json, ev.cues_json, ev.mistakes_json, ev.safety_json
                    FROM exercises AS e
                    JOIN exercise_versions AS ev ON ev.exercise_id = e.id
                    WHERE e.id = :exercise_id
                      AND ev.version_no = :version_no
                      AND e.status IN ('draft', 'published')
                      AND ev.status = 'draft'
                      AND e.owner_user_id = :owner_user_id
                    """
                ),
                {"exercise_id": exercise_id, "version_no": version_no, "owner_user_id": principal.user_id},
            )
        ).mappings().one_or_none()
        if version is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Owned draft exercise version not found")
        tag_rows = await session.execute(
            text(
                """
                SELECT term.dimension, term.code
                FROM exercise_terms AS et
                JOIN taxonomy_terms AS term ON term.id = et.term_id
                WHERE et.exercise_version_id = :version_id
                ORDER BY term.dimension, term.sort_order, term.code
                """
            ),
            {"version_id": version["version_id"]},
        )
        media_rows = await session.execute(
            text(
                """
                SELECT id, media_type, object_key, preview_object_key, content_type, alt_text_zh, duration_ms
                FROM exercise_media
                WHERE exercise_version_id = :version_id AND status IN ('draft', 'ready')
                ORDER BY media_type, created_at
                """
            ),
            {"version_id": version["version_id"]},
        )
    tags: dict[str, list[str]] = defaultdict(list)
    for row in tag_rows.mappings():
        tags[str(row["dimension"])].append(str(row["code"]))
    return ExerciseDetailResponse(
        id=version["id"],
        version_no=version["version_no"],
        name_zh=version["name_zh"],
        name_en=version["name_en"],
        summary=version["summary"],
        recording_mode=version["recording_mode"],
        purposes=tags.get("purpose", []),
        instructions=version["instructions_json"],
        cues=version["cues_json"],
        mistakes=version["mistakes_json"],
        safety_notes=version["safety_json"],
        tags=dict(tags),
        media=[ExerciseMediaResponse.model_validate(row) for row in media_rows.mappings()],
    )


@router.put("/exercises/{exercise_id}/versions/{version_no}", response_model=ExerciseDraftResponse)
async def update_exercise_draft(
    exercise_id: UUID,
    version_no: int,
    request: ExerciseDraftRequest,
    principal: Annotated[Principal, Depends(require_owner)],
) -> ExerciseDraftResponse:
    """Replace the editable text and taxonomy of an unpublished owner draft."""

    content_hash = _content_hash(request)
    async with system_transaction() as session:
        version = (
            await session.execute(
                text(
                    """
                    SELECT ev.id
                    FROM exercise_versions AS ev
                    JOIN exercises AS e ON e.id = ev.exercise_id
                    WHERE ev.exercise_id = :exercise_id
                      AND ev.version_no = :version_no
                      AND ev.status = 'draft'
                      AND e.status IN ('draft', 'published')
                      AND e.owner_user_id = :owner_user_id
                    FOR UPDATE OF ev
                    """
                ),
                {
                    "exercise_id": exercise_id,
                    "version_no": version_no,
                    "owner_user_id": principal.user_id,
                },
            )
        ).mappings().one_or_none()
        if version is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Owned draft exercise version not found")
        tag_ids = await _resolve_tag_ids(session, request.tags)
        await session.execute(
            text(
                """
                UPDATE exercise_versions
                SET name_zh = :name_zh,
                    name_en = :name_en,
                    summary = :summary,
                    instructions_json = CAST(:instructions AS jsonb),
                    cues_json = CAST(:cues AS jsonb),
                    mistakes_json = CAST(:mistakes AS jsonb),
                    safety_json = CAST(:safety_notes AS jsonb),
                    recording_mode = :recording_mode,
                    content_hash = :content_hash,
                    change_summary = :change_summary
                WHERE id = :version_id
                """
            ),
            {
                "version_id": version["id"],
                "name_zh": request.name_zh,
                "name_en": request.name_en,
                "summary": request.summary,
                "instructions": json.dumps(request.instructions, ensure_ascii=False),
                "cues": json.dumps(request.cues, ensure_ascii=False),
                "mistakes": json.dumps(request.mistakes, ensure_ascii=False),
                "safety_notes": json.dumps(request.safety_notes, ensure_ascii=False),
                "recording_mode": request.recording_mode,
                "content_hash": content_hash,
                "change_summary": request.change_summary,
            },
        )
        await session.execute(
            text("DELETE FROM exercise_terms WHERE exercise_version_id = :version_id"),
            {"version_id": version["id"]},
        )
        for term_id in tag_ids:
            await session.execute(
                text(
                    """
                    INSERT INTO exercise_terms (exercise_version_id, term_id, is_primary)
                    VALUES (:exercise_version_id, :term_id, false)
                    """
                ),
                {"exercise_version_id": version["id"], "term_id": term_id},
            )

    return ExerciseDraftResponse(id=exercise_id, version_no=version_no, status="draft")


@router.post(
    "/exercises/{exercise_id}/versions/draft",
    response_model=ExerciseDraftResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_draft_from_published_version(
    exercise_id: UUID,
    principal: Annotated[Principal, Depends(require_owner)],
) -> ExerciseDraftResponse:
    """Create the single editable successor of an owned published exercise.

    Published versions and their release records are never mutated.  The new
    draft copies textual content, taxonomy and media *references*; a draft can
    therefore remove an inherited item without affecting the released version.
    Physical files are only removed when no version still references them.
    """

    draft_version_id = uuid4()
    async with system_transaction() as session:
        exercise = (
            await session.execute(
                text(
                    """
                    SELECT id, current_published_version
                    FROM exercises
                    WHERE id = :exercise_id
                      AND status = 'published'
                      AND owner_user_id = :owner_user_id
                    FOR UPDATE
                    """
                ),
                {"exercise_id": exercise_id, "owner_user_id": principal.user_id},
            )
        ).mappings().one_or_none()
        if exercise is None or exercise["current_published_version"] is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Owned published exercise not found")

        existing_draft = await session.scalar(
            text(
                """
                SELECT EXISTS (
                    SELECT 1 FROM exercise_versions
                    WHERE exercise_id = :exercise_id AND status = 'draft'
                )
                """
            ),
            {"exercise_id": exercise_id},
        )
        if existing_draft is True:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="This exercise already has an editable draft version.",
            )

        source = (
            await session.execute(
                text(
                    """
                    SELECT id, name_zh, name_en, summary, instructions_json, cues_json,
                           mistakes_json, safety_json, recording_mode, content_hash
                    FROM exercise_versions
                    WHERE exercise_id = :exercise_id
                      AND version_no = :version_no
                      AND status = 'published'
                    """
                ),
                {"exercise_id": exercise_id, "version_no": exercise["current_published_version"]},
            )
        ).mappings().one_or_none()
        if source is None:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Published version is unavailable")

        draft_version_no = int(
            await session.scalar(
                text(
                    """
                    SELECT COALESCE(MAX(version_no), 0) + 1
                    FROM exercise_versions
                    WHERE exercise_id = :exercise_id
                    """
                ),
                {"exercise_id": exercise_id},
            )
            or 1
        )
        await session.execute(
            text(
                """
                INSERT INTO exercise_versions (
                    id, exercise_id, version_no, status, name_zh, name_en, summary,
                    instructions_json, cues_json, mistakes_json, safety_json, recording_mode,
                    content_hash, author_user_id, change_summary
                ) VALUES (
                    :id, :exercise_id, :version_no, 'draft', :name_zh, :name_en, :summary,
                    CAST(:instructions AS jsonb), CAST(:cues AS jsonb), CAST(:mistakes AS jsonb),
                    CAST(:safety_notes AS jsonb), :recording_mode, :content_hash, :author_user_id,
                    :change_summary
                )
                """
            ),
            {
                "id": draft_version_id,
                "exercise_id": exercise_id,
                "version_no": draft_version_no,
                "name_zh": source["name_zh"],
                "name_en": source["name_en"],
                "summary": source["summary"],
                "instructions": json.dumps(source["instructions_json"], ensure_ascii=False),
                "cues": json.dumps(source["cues_json"], ensure_ascii=False),
                "mistakes": json.dumps(source["mistakes_json"], ensure_ascii=False),
                "safety_notes": json.dumps(source["safety_json"], ensure_ascii=False),
                "recording_mode": source["recording_mode"],
                "content_hash": source["content_hash"],
                "author_user_id": principal.user_id,
                "change_summary": "Based on published version",
            },
        )
        await session.execute(
            text(
                """
                INSERT INTO exercise_terms (exercise_version_id, term_id, is_primary)
                SELECT :draft_version_id, term_id, is_primary
                FROM exercise_terms
                WHERE exercise_version_id = :source_version_id
                """
            ),
            {"draft_version_id": draft_version_id, "source_version_id": source["id"]},
        )
        source_media = list(
            (
                await session.execute(
                    text(
                        """
                        SELECT media_type, object_key, preview_object_key, sha256, width, height,
                               duration_ms, content_type, license_type, rights_holder,
                               rights_expires_at, alt_text_zh
                        FROM exercise_media
                        WHERE exercise_version_id = :source_version_id AND status = 'published'
                        ORDER BY created_at, id
                        """
                    ),
                    {"source_version_id": source["id"]},
                )
            ).mappings()
        )
        await _lock_media_object_keys(
            session,
            [
                key
                for media in source_media
                for key in (media["object_key"], media["preview_object_key"])
                if key is not None
            ],
        )
        for media in source_media:
            await session.execute(
                text(
                    """
                    INSERT INTO exercise_media (
                        id, exercise_version_id, media_type, object_key, preview_object_key, sha256,
                        width, height, duration_ms, content_type, license_type, rights_holder,
                        rights_expires_at, alt_text_zh, status
                    ) VALUES (
                        :id, :exercise_version_id, :media_type, :object_key, :preview_object_key, :sha256,
                        :width, :height, :duration_ms, :content_type, :license_type, :rights_holder,
                        :rights_expires_at, :alt_text_zh, 'ready'
                    )
                    """
                ),
                {"id": uuid4(), "exercise_version_id": draft_version_id, **dict(media)},
            )

    return ExerciseDraftResponse(id=exercise_id, version_no=draft_version_no, status="draft")


@router.post(
    "/exercises/{exercise_id}/versions/{version_no}/media",
    response_model=ExerciseMediaResponse,
    status_code=status.HTTP_201_CREATED,
)
async def upload_draft_media(
    exercise_id: UUID,
    version_no: int,
    principal: Annotated[Principal, Depends(require_owner)],
    file: Annotated[UploadFile, File(...)],
    alt_text_zh: Annotated[str, Form(min_length=8, max_length=240)],
    media_type: Annotated[str, Form()] = "video",
) -> ExerciseMediaResponse:
    """Store one owner-uploaded media file in local-personal mode.

    The byte stream is hashed by the server, recorded as ready only after the
    complete write succeeds, and is then served read-only at ``/media``.  This
    is intentionally a local-development adapter; the object key remains a
    stable abstraction for a later S3/OSS presigned-upload adapter.
    """

    if media_type not in {"video", "image", "cover", "keyframe"}:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="Unsupported media type")
    content_type = (file.content_type or "application/octet-stream").lower()
    suffix = Path(file.filename or "").suffix.lower()
    if content_type == "application/octet-stream":
        content_type = _MEDIA_MIME_BY_EXTENSION.get(suffix, content_type)
    if not content_type.startswith(("video/", "image/")):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=(
                "Only video and image uploads are supported; "
                f"received content type {content_type!r}."
            ),
        )

    async with system_transaction() as session:
        version = (
            await session.execute(
                text(
                    """
                    SELECT version.id
                    FROM exercise_versions AS version
                    JOIN exercises AS exercise ON exercise.id = version.exercise_id
                    WHERE version.exercise_id = :exercise_id
                      AND version.version_no = :version_no
                      AND version.status = 'draft'
                      AND exercise.status IN ('draft', 'published')
                      AND exercise.owner_user_id = :owner_user_id
                    """
                ),
                {"exercise_id": exercise_id, "version_no": version_no, "owner_user_id": principal.user_id},
            )
        ).mappings().one_or_none()
    if version is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Owned draft exercise version not found")

    settings = get_settings()
    if not _SAFE_EXTENSION.fullmatch(suffix):
        suffix = ".mp4" if content_type.startswith("video/") else ".jpg"
    media_id = uuid4()
    object_key = f"local/{exercise_id}/{version_no}/{media_id}{suffix}"
    destination = settings.local_media_root / object_key
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(f"{destination.suffix}.upload")
    digest = sha256()
    bytes_written = 0
    try:
        with temporary.open("xb") as output:
            while chunk := await file.read(1024 * 1024):
                bytes_written += len(chunk)
                if bytes_written > settings.local_media_max_bytes:
                    raise HTTPException(
                        status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                        detail="Media file exceeds the configured local upload limit.",
                    )
                digest.update(chunk)
                output.write(chunk)
        if bytes_written == 0:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="Media file is empty.")
        temporary.replace(destination)
    except Exception:
        temporary.unlink(missing_ok=True)
        destination.unlink(missing_ok=True)
        raise
    finally:
        await file.close()

    try:
        async with system_transaction() as session:
            await session.execute(
                text(
                    """
                    INSERT INTO exercise_media (
                        id, exercise_version_id, media_type, object_key, sha256,
                        content_type, license_type, rights_holder, alt_text_zh, status
                    ) VALUES (
                        :id, :exercise_version_id, :media_type, :object_key, :sha256,
                        :content_type, 'user_owned', :rights_holder, :alt_text_zh, 'ready'
                    )
                    """
                ),
                {
                    "id": media_id,
                    "exercise_version_id": version["id"],
                    "media_type": media_type,
                    "object_key": object_key,
                    "sha256": digest.hexdigest(),
                    "content_type": content_type,
                    "rights_holder": str(principal.user_id),
                    "alt_text_zh": alt_text_zh.strip(),
                },
            )
    except Exception:
        destination.unlink(missing_ok=True)
        raise

    return ExerciseMediaResponse(
        id=media_id,
        media_type=media_type,
        object_key=object_key,
        preview_object_key=None,
        content_type=content_type,
        alt_text_zh=alt_text_zh.strip(),
        duration_ms=None,
    )


@router.delete("/media/{media_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_draft_media(
    media_id: UUID,
    principal: Annotated[Principal, Depends(require_owner)],
) -> Response:
    """Remove one media attachment from an editable owner draft.

    A release only serves ``published`` media, and this query only targets a
    ``draft`` version.  It is therefore impossible for this route to alter a
    released action or a media item owned by someone else.
    """

    async with system_transaction() as session:
        media = (
            await session.execute(
                text(
                    """
                    SELECT media.object_key, media.preview_object_key
                    FROM exercise_media AS media
                    JOIN exercise_versions AS version ON version.id = media.exercise_version_id
                    JOIN exercises AS exercise ON exercise.id = version.exercise_id
                    WHERE media.id = :media_id
                      AND version.status = 'draft'
                      AND exercise.status IN ('draft', 'published')
                      AND exercise.owner_user_id = :owner_user_id
                    FOR UPDATE OF media, version, exercise
                    """
                ),
                {"media_id": media_id, "owner_user_id": principal.user_id},
            )
        ).mappings().one_or_none()
        if media is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Owned draft media not found")
        object_keys = [
            key for key in (media["object_key"], media["preview_object_key"]) if key is not None
        ]
        await _lock_media_object_keys(session, object_keys)
        await session.execute(text("DELETE FROM exercise_media WHERE id = :media_id"), {"media_id": media_id})
        await _delete_unreferenced_local_files(session, object_keys)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete(
    "/drafts/{exercise_id}/versions/{version_no}",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def delete_owner_draft(
    exercise_id: UUID,
    version_no: int,
    principal: Annotated[Principal, Depends(require_owner)],
) -> Response:
    """Abandon a draft version without touching published history.

    For an action that has never been released this also removes the otherwise
    empty exercise container.  For an already published action it removes only
    the editable successor, leaving every released version and its manifest
    history intact.
    """

    async with system_transaction() as session:
        draft = (
            await session.execute(
                text(
                    """
                    SELECT version.id AS version_id, exercise.status AS exercise_status
                    FROM exercise_versions AS version
                    JOIN exercises AS exercise ON exercise.id = version.exercise_id
                    WHERE version.exercise_id = :exercise_id
                      AND version.version_no = :version_no
                      AND version.status = 'draft'
                      AND exercise.status IN ('draft', 'published')
                      AND exercise.owner_user_id = :owner_user_id
                    FOR UPDATE OF version, exercise
                    """
                ),
                {
                    "exercise_id": exercise_id,
                    "version_no": version_no,
                    "owner_user_id": principal.user_id,
                },
            )
        ).mappings().one_or_none()
        if draft is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Owned draft exercise version not found")

        media_rows = list(
            (
                await session.execute(
                    text(
                        """
                        SELECT object_key, preview_object_key
                        FROM exercise_media
                        WHERE exercise_version_id = :version_id
                        FOR UPDATE
                        """
                    ),
                    {"version_id": draft["version_id"]},
                )
            ).mappings()
        )
        object_keys = [
            key
            for media in media_rows
            for key in (media["object_key"], media["preview_object_key"])
            if key is not None
        ]
        await _lock_media_object_keys(session, object_keys)
        # Delete attachments explicitly before deleting the version so we can
        # count references and clean up only unshared local files.
        await session.execute(
            text("DELETE FROM exercise_media WHERE exercise_version_id = :version_id"),
            {"version_id": draft["version_id"]},
        )
        await session.execute(
            text("DELETE FROM exercise_versions WHERE id = :version_id"),
            {"version_id": draft["version_id"]},
        )
        if draft["exercise_status"] == "draft":
            await session.execute(
                text(
                    """
                    DELETE FROM exercises
                    WHERE id = :exercise_id
                      AND status = 'draft'
                      AND NOT EXISTS (
                        SELECT 1 FROM exercise_versions WHERE exercise_id = :exercise_id
                      )
                    """
                ),
                {"exercise_id": exercise_id},
            )
        await _delete_unreferenced_local_files(session, object_keys)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/media/{media_id}/ready", status_code=status.HTTP_204_NO_CONTENT)
async def mark_media_ready(
    media_id: UUID,
    request: MarkMediaReadyRequest,
    principal: Annotated[Principal, Depends(require_owner)],
) -> None:
    async with system_transaction() as session:
        row = (
            await session.execute(
                text(
                    """
                    UPDATE exercise_media AS media
                    SET status = 'ready'
                    FROM exercise_versions AS version
                    JOIN exercises AS exercise ON exercise.id = version.exercise_id
                    WHERE media.id = :media_id
                      AND media.exercise_version_id = version.id
                      AND exercise.owner_user_id = :owner_user_id
                      AND version.status = 'draft'
                      AND exercise.status IN ('draft', 'published')
                      AND media.status = 'draft'
                      AND media.sha256 = :verified_sha256
                    RETURNING media.id
                    """
                ),
                {
                    "media_id": media_id,
                    "owner_user_id": principal.user_id,
                    "verified_sha256": request.verified_sha256,
                },
            )
        ).mappings().one_or_none()
        if row is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Draft media was not found or its verification hash does not match.",
            )


@router.post(
    "/exercises/{exercise_id}/versions/{version_no}/publish",
    response_model=PublishExerciseResponse,
)
async def publish_exercise_version(
    exercise_id: UUID,
    version_no: int,
    principal: Annotated[Principal, Depends(require_owner)],
) -> PublishExerciseResponse:
    async with system_transaction() as session:
        version = (
            await session.execute(
                text(
                    """
                    SELECT version.id, version.content_hash, version.name_zh, version.summary,
                           version.instructions_json, version.cues_json,
                           version.mistakes_json, version.safety_json
                    FROM exercise_versions AS version
                    JOIN exercises AS exercise ON exercise.id = version.exercise_id
                    WHERE version.exercise_id = :exercise_id
                      AND version.version_no = :version_no
                      AND version.status = 'draft'
                      AND exercise.owner_user_id = :owner_user_id
                      AND exercise.status IN ('draft', 'published')
                    """
                ),
                {
                    "exercise_id": exercise_id,
                    "version_no": version_no,
                    "owner_user_id": principal.user_id,
                },
            )
        ).mappings().one_or_none()
        if version is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Publishable draft version not found")

        purpose_count = int(
            await session.scalar(
                text(
                    """
                    SELECT count(*)
                    FROM exercise_terms AS et
                    JOIN taxonomy_terms AS term ON term.id = et.term_id
                    WHERE et.exercise_version_id = :version_id AND term.dimension = 'purpose'
                    """
                ),
                {"version_id": version["id"]},
            )
            or 0
        )
        missing_fields: list[str] = []
        if len(str(version["summary"]).strip()) < 10:
            missing_fields.append("简述（至少 10 个字符）")
        if len(version["instructions_json"]) < 3:
            missing_fields.append("至少 3 条动作步骤")
        if len(version["cues_json"]) < 3:
            missing_fields.append("至少 3 条执行要点")
        if len(version["mistakes_json"]) < 2:
            missing_fields.append("至少 2 条常见错误")
        if len(version["safety_json"]) < 1:
            missing_fields.append("至少 1 条安全提示")
        if purpose_count == 0:
            missing_fields.append("训练阶段用途")
        # A personal owner may intentionally publish a name-only exercise.
        # Supporting content remains recommended, but never blocks a reviewed
        # owner from using a simple movement in a plan.
        if not str(version["name_zh"] or "").strip():
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail={"message": "An exercise name is required.", "missing": ["name_zh"]},
            )
        # This personal library deliberately permits name-only actions.
        missing_fields.clear()
        if missing_fields:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail={"message": "Draft is incomplete and cannot be published.", "missing": missing_fields},
            )

        media_rows = await session.execute(
            text(
                """
                SELECT id, sha256
                FROM exercise_media
                WHERE exercise_version_id = :version_id AND status = 'ready'
                ORDER BY id
                """
            ),
            {"version_id": version["id"]},
        )
        media = list(media_rows.mappings())
        media_is_required = False
        if media_is_required and not media:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="At least one verified media item is required before publishing.",
            )

        await _lock_library_releases(session)
        release_no = int(
            await session.scalar(text("SELECT COALESCE(MAX(release_no), 0) + 1 FROM library_releases"))
        )
        release_id = uuid4()

        await session.execute(
            text(
                """
                UPDATE exercise_versions
                SET status = 'published', reviewed_by_user_id = :reviewer_id,
                    reviewed_at = now(), published_at = now()
                WHERE id = :version_id
                """
            ),
            {"version_id": version["id"], "reviewer_id": principal.user_id},
        )
        await session.execute(
            text(
                """
                UPDATE exercises
                SET status = 'published', current_published_version = :version_no, updated_at = now()
                WHERE id = :exercise_id
                """
            ),
            {"exercise_id": exercise_id, "version_no": version_no},
        )
        await session.execute(
            text(
                """
                UPDATE exercise_media
                SET status = 'published'
                WHERE exercise_version_id = :version_id AND status = 'ready'
                """
            ),
            {"version_id": version["id"]},
        )
        # A release manifest represents the complete target library state.  A
        # one-item hash would let a client incorrectly treat a multi-release
        # delta as a full snapshot.
        manifest_hash = await _current_snapshot_hash(session)
        await session.execute(
            text(
                """
                INSERT INTO library_releases (
                    id, release_no, status, manifest_hash, min_client_schema, published_by_user_id, published_at
                ) VALUES (:id, :release_no, 'published', :manifest_hash, 1, :publisher_id, now())
                """
            ),
            {
                "id": release_id,
                "release_no": release_no,
                "manifest_hash": manifest_hash,
                "publisher_id": principal.user_id,
            },
        )
        await session.execute(
            text(
                "INSERT INTO library_release_items (release_id, exercise_version_id) VALUES (:release_id, :version_id)"
            ),
            {"release_id": release_id, "version_id": version["id"]},
        )

    return PublishExerciseResponse(
        exercise_id=exercise_id,
        version_no=version_no,
        release_no=release_no,
        manifest_hash=manifest_hash,
    )


@router.get("/exercises", response_model=list[ExerciseSummaryResponse])
async def list_exercises(
    search: Annotated[str | None, Query(min_length=1, max_length=80)] = None,
    purpose: Annotated[str | None, Query(pattern=r"^[a-z_]+$")] = None,
    tag: Annotated[list[str] | None, Query(pattern=r"^[a-z_]+:[a-z0-9_.-]+$")] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> list[ExerciseSummaryResponse]:
    """List published actions; every ``tag=dimension:code`` must match."""

    tag_filters: list[str] = []
    params: dict[str, object] = {"search": search, "purpose": purpose, "limit": limit, "offset": offset}
    for index, item in enumerate(tag or []):
        dimension, _, code = item.partition(":")
        tag_filters.append(
            f"""
            AND EXISTS (
                SELECT 1
                FROM exercise_terms AS filter_et{index}
                JOIN taxonomy_terms AS filter_term{index}
                  ON filter_term{index}.id = filter_et{index}.term_id
                WHERE filter_et{index}.exercise_version_id = ev.id
                  AND filter_term{index}.dimension = :tag_dimension_{index}
                  AND filter_term{index}.code = :tag_code_{index}
            )
            """
        )
        params[f"tag_dimension_{index}"] = dimension
        params[f"tag_code_{index}"] = code

    async with system_transaction() as session:
        result = await session.execute(
            text(
                """
                SELECT
                    e.id,
                    ev.version_no,
                    ev.name_zh,
                    ev.name_en,
                    ev.summary,
                    ev.recording_mode,
                    COALESCE(
                        array_agg(DISTINCT purpose_term.code)
                            FILTER (WHERE purpose_term.code IS NOT NULL),
                        ARRAY[]::text[]
                    ) AS purposes
                FROM exercises AS e
                JOIN exercise_versions AS ev
                  ON ev.exercise_id = e.id
                 AND ev.version_no = e.current_published_version
                LEFT JOIN exercise_terms AS et ON et.exercise_version_id = ev.id
                LEFT JOIN taxonomy_terms AS purpose_term
                  ON purpose_term.id = et.term_id
                 AND purpose_term.dimension = 'purpose'
                WHERE e.status = 'published'
                  AND ev.status = 'published'
                  AND (
                    CAST(:search AS text) IS NULL
                    OR ev.name_zh ILIKE '%' || CAST(:search AS text) || '%'
                    OR ev.name_en ILIKE '%' || CAST(:search AS text) || '%'
                  )
                  AND (
                    CAST(:purpose AS text) IS NULL OR EXISTS (
                        SELECT 1
                        FROM exercise_terms AS filter_et
                        JOIN taxonomy_terms AS filter_term ON filter_term.id = filter_et.term_id
                        WHERE filter_et.exercise_version_id = ev.id
                          AND filter_term.dimension = 'purpose'
                          AND filter_term.code = CAST(:purpose AS text)
                    )
                  )
                """ + "".join(tag_filters) + """
                GROUP BY e.id, ev.version_no, ev.name_zh, ev.name_en, ev.summary, ev.recording_mode
                ORDER BY ev.name_zh, e.id
                LIMIT :limit OFFSET :offset
                """
            ),
            params,
        )
        return [ExerciseSummaryResponse.model_validate(row) for row in result.mappings()]


@router.get("/exercises/{exercise_id}/versions/{version_no}", response_model=ExerciseDetailResponse)
async def get_published_exercise_version(
    exercise_id: UUID,
    version_no: int,
) -> ExerciseDetailResponse:
    """Fetch the immutable payload referenced by a delta or snapshot item."""

    async with system_transaction() as session:
        version = (
            await session.execute(
                text(
                    """
                    SELECT e.id, ev.id AS version_id, ev.version_no, ev.name_zh, ev.name_en, ev.summary,
                           ev.recording_mode, ev.instructions_json, ev.cues_json, ev.mistakes_json, ev.safety_json
                    FROM exercises AS e
                    JOIN exercise_versions AS ev ON ev.exercise_id = e.id
                    WHERE e.id = :exercise_id
                      AND ev.version_no = :version_no
                      AND e.status IN ('published', 'deprecated')
                      AND ev.status = 'published'
                    """
                ),
                {"exercise_id": exercise_id, "version_no": version_no},
            )
        ).mappings().one_or_none()
        if version is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Published exercise version not found")

        tag_rows = await session.execute(
            text(
                """
                SELECT term.dimension, term.code
                FROM exercise_terms AS et
                JOIN taxonomy_terms AS term ON term.id = et.term_id
                WHERE et.exercise_version_id = :version_id
                ORDER BY term.dimension, term.sort_order, term.code
                """
            ),
            {"version_id": version["version_id"]},
        )
        tags: dict[str, list[str]] = defaultdict(list)
        for row in tag_rows.mappings():
            tags[str(row["dimension"])].append(str(row["code"]))

        media_rows = await session.execute(
            text(
                """
                SELECT id, media_type, object_key, preview_object_key, content_type, alt_text_zh, duration_ms
                FROM exercise_media
                WHERE exercise_version_id = :version_id AND status = 'published'
                ORDER BY media_type, created_at
                """
            ),
            {"version_id": version["version_id"]},
        )

    return ExerciseDetailResponse(
        id=version["id"],
        version_no=version["version_no"],
        name_zh=version["name_zh"],
        name_en=version["name_en"],
        summary=version["summary"],
        recording_mode=version["recording_mode"],
        purposes=tags.get("purpose", []),
        instructions=version["instructions_json"],
        cues=version["cues_json"],
        mistakes=version["mistakes_json"],
        safety_notes=version["safety_json"],
        tags=dict(tags),
        media=[ExerciseMediaResponse.model_validate(row) for row in media_rows.mappings()],
    )


@router.post("/exercises/{exercise_id}/deprecate", status_code=status.HTTP_204_NO_CONTENT)
async def deprecate_exercise(
    exercise_id: UUID,
    principal: Annotated[Principal, Depends(require_owner)],
) -> Response:
    """Stop recommending an owned published exercise in new plans.

    History keeps its snapshot; existing workouts are untouched.  The
    exercise simply disappears from the published list and can no longer be
    added to a new plan slot.
    """

    async with system_transaction() as session:
        row = (
            await session.execute(
                text(
                    """
                    UPDATE exercises
                    SET status = 'deprecated', updated_at = now()
                    WHERE id = :exercise_id
                      AND status = 'published'
                      AND owner_user_id = :owner_user_id
                    RETURNING id
                    """
                ),
                {"exercise_id": exercise_id, "owner_user_id": principal.user_id},
            )
        ).mappings().one_or_none()
        if row is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Owned published exercise not found or already withdrawn.",
            )
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/exercises/{exercise_id}", response_model=ExerciseDetailResponse)
async def get_exercise(
    exercise_id: UUID,
) -> ExerciseDetailResponse:
    async with system_transaction() as session:
        version = (
            await session.execute(
                text(
                    """
                    SELECT e.id, ev.id AS version_id, ev.version_no, ev.name_zh, ev.name_en, ev.summary,
                           ev.recording_mode, ev.instructions_json, ev.cues_json, ev.mistakes_json, ev.safety_json
                    FROM exercises AS e
                    JOIN exercise_versions AS ev
                      ON ev.exercise_id = e.id
                     AND ev.version_no = e.current_published_version
                    WHERE e.id = :exercise_id AND e.status = 'published' AND ev.status = 'published'
                    """
                ),
                {"exercise_id": exercise_id},
            )
        ).mappings().one_or_none()
        if version is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Published exercise not found")

        tag_rows = await session.execute(
            text(
                """
                SELECT term.dimension, term.code
                FROM exercise_terms AS et
                JOIN taxonomy_terms AS term ON term.id = et.term_id
                WHERE et.exercise_version_id = :version_id
                ORDER BY term.dimension, term.sort_order, term.code
                """
            ),
            {"version_id": version["version_id"]},
        )
        tags: dict[str, list[str]] = defaultdict(list)
        for row in tag_rows.mappings():
            tags[str(row["dimension"])].append(str(row["code"]))

        media_rows = await session.execute(
            text(
                """
                SELECT id, media_type, object_key, preview_object_key, content_type, alt_text_zh, duration_ms
                FROM exercise_media
                WHERE exercise_version_id = :version_id AND status = 'published'
                ORDER BY media_type, created_at
                """
            ),
            {"version_id": version["version_id"]},
        )

    return ExerciseDetailResponse(
        id=version["id"],
        version_no=version["version_no"],
        name_zh=version["name_zh"],
        name_en=version["name_en"],
        summary=version["summary"],
        recording_mode=version["recording_mode"],
        purposes=tags.get("purpose", []),
        instructions=version["instructions_json"],
        cues=version["cues_json"],
        mistakes=version["mistakes_json"],
        safety_notes=version["safety_json"],
        tags=dict(tags),
        media=[ExerciseMediaResponse.model_validate(row) for row in media_rows.mappings()],
    )
