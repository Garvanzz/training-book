from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator


class LoginRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    email: str = Field(min_length=3, max_length=320)
    password: str = Field(min_length=12, max_length=1024)
    device_id: UUID
    device_name: str = Field(min_length=1, max_length=120)
    platform: Literal["ios", "windows"]

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: str) -> str:
        return value.strip().lower()


class RefreshRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    refresh_token: str = Field(min_length=32, max_length=1024)
    device_id: UUID


class SessionResponse(BaseModel):
    access_token: str
    refresh_token: str
    expires_in_seconds: int
    offline_lease_expires_at: datetime


class RegisterRequest(LoginRequest):
    """Create a regular (non-owner) account; owner is bootstrapped by CLI only."""

    model_config = ConfigDict(extra="forbid")

    display_name: str = Field(default="训练者", min_length=1, max_length=120)


class RegistrationStatusResponse(BaseModel):
    enabled: bool


class AuthMeResponse(BaseModel):
    user_id: UUID
    email: str
    is_owner: bool


class SyncOperation(BaseModel):
    model_config = ConfigDict(extra="forbid")

    operation_id: UUID
    entity_type: str = Field(min_length=1, max_length=80)
    entity_id: UUID
    operation_type: Literal["create", "update", "delete"]
    base_revision: int | None = Field(default=None, ge=1)
    payload: dict[str, object]


class SyncPushRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    device_id: UUID
    operations: list[SyncOperation] = Field(min_length=1, max_length=100)


class OperationResult(BaseModel):
    operation_id: UUID
    result: Literal["accepted", "conflict", "rejected"]
    server_revision: int | None = None
    detail: dict[str, object] = Field(default_factory=dict)


class SyncPushResponse(BaseModel):
    results: list[OperationResult]
    next_cursor: int


class SyncPullChange(BaseModel):
    """An immutable journal entry returned to an authenticated user's devices.

    ``result`` is deliberately included: rejected and conflicting operations
    advance the cursor too, so a client can safely discard them and continue
    without repeatedly fetching an unapplicable operation.
    """

    server_cursor: int = Field(ge=1)
    operation_id: UUID
    device_id: UUID
    entity_type: str
    entity_id: UUID
    operation_type: Literal["create", "update", "delete"]
    base_revision: int | None = Field(default=None, ge=1)
    payload: dict[str, object]
    result: Literal["accepted", "conflict", "rejected"]
    server_revision: int | None = Field(default=None, ge=1)
    detail: dict[str, object] = Field(default_factory=dict)
    created_at: datetime


class SyncPullResponse(BaseModel):
    changes: list[SyncPullChange]
    next_cursor: int = Field(ge=0)
    has_more: bool


class TaxonomyTermResponse(BaseModel):
    id: UUID
    dimension: str
    code: str
    name_zh: str
    sort_order: int


class ExerciseSummaryResponse(BaseModel):
    id: UUID
    version_no: int
    name_zh: str
    name_en: str | None
    summary: str
    recording_mode: str
    purposes: list[str]


class ExerciseMediaResponse(BaseModel):
    id: UUID
    media_type: str
    object_key: str
    preview_object_key: str | None
    content_type: str
    alt_text_zh: str
    duration_ms: int | None


class ExerciseDetailResponse(ExerciseSummaryResponse):
    instructions: list[str]
    cues: list[str]
    mistakes: list[str]
    safety_notes: list[str]
    tags: dict[str, list[str]]
    media: list[ExerciseMediaResponse]


class ExerciseMediaDraft(BaseModel):
    model_config = ConfigDict(extra="forbid")

    media_type: Literal["video", "image", "cover", "keyframe"]
    object_key: str = Field(min_length=8, max_length=512)
    preview_object_key: str | None = Field(default=None, max_length=512)
    sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    content_type: str = Field(min_length=3, max_length=120)
    alt_text_zh: str = Field(min_length=8, max_length=240)
    license_type: str = Field(min_length=2, max_length=60)
    rights_holder: str = Field(min_length=2, max_length=120)
    duration_ms: int | None = Field(default=None, ge=0)


class ExerciseDraftRequest(BaseModel):
    """Partial owner-authored content. Completeness is enforced at publish time."""

    model_config = ConfigDict(extra="forbid")

    name_zh: str = Field(min_length=2, max_length=80)
    name_en: str | None = Field(default=None, max_length=120)
    summary: str = Field(default="", max_length=240)
    recording_mode: Literal[
        "load_reps", "duration", "distance", "load_duration", "assisted_bodyweight", "mixed"
    ] = "load_reps"
    instructions: list[str] = Field(default_factory=list, max_length=12)
    cues: list[str] = Field(default_factory=list, max_length=6)
    mistakes: list[str] = Field(default_factory=list, max_length=5)
    safety_notes: list[str] = Field(default_factory=list, max_length=6)
    tags: dict[str, list[str]] = Field(default_factory=dict)
    media: list[ExerciseMediaDraft] = Field(default_factory=list, max_length=10)
    change_summary: str = Field(default="首次草稿", min_length=2, max_length=240)


class ExerciseDraftResponse(BaseModel):
    id: UUID
    version_no: int
    status: Literal["draft"]


class MarkMediaReadyRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    verified_sha256: str = Field(pattern=r"^[a-f0-9]{64}$")


class PublishExerciseResponse(BaseModel):
    exercise_id: UUID
    version_no: int
    release_no: int
    manifest_hash: str


class LibraryManifestResponse(BaseModel):
    release_no: int = Field(ge=0)
    manifest_hash: str
    min_client_schema: int = Field(ge=1)
    change: Literal["none", "delta", "snapshot"]
    # These values are an immutable synchronization target.  A client must use
    # the exact range returned here rather than chase a moving latest release.
    delta_after_release: int | None = Field(default=None, ge=0)
    delta_through_release: int | None = Field(default=None, ge=0)
    snapshot_release: int | None = Field(default=None, ge=0)
    download_url: str | None = None


class LibraryReleaseItemResponse(BaseModel):
    exercise_id: UUID
    version_no: int
    name_zh: str
    recording_mode: str
    content_hash: str


class LibraryReleaseDeltaResponse(BaseModel):
    release_no: int = Field(ge=1)
    manifest_hash: str
    min_client_schema: int = Field(ge=1)
    items: list[LibraryReleaseItemResponse]


class LibraryDeltaResponse(BaseModel):
    after_release: int = Field(ge=0)
    through_release: int = Field(ge=0)
    next_after_release: int = Field(ge=0)
    manifest_hash: str
    min_client_schema: int = Field(ge=1)
    releases: list[LibraryReleaseDeltaResponse]
    has_more: bool


class LibrarySnapshotResponse(BaseModel):
    release_no: int = Field(ge=0)
    manifest_hash: str
    min_client_schema: int = Field(ge=1)
    items: list[LibraryReleaseItemResponse]


class PrescriptionInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    prescription_type: Literal[
        "fixed_sets_reps", "rep_range", "amrap", "emom", "duration", "distance", "free"
    ]
    set_count: int | None = Field(default=None, ge=1, le=100)
    rep_min: int | None = Field(default=None, ge=0, le=1000)
    rep_max: int | None = Field(default=None, ge=0, le=1000)
    target_load_kg: float | None = Field(default=None, ge=0, le=2000)
    target_rpe: float | None = Field(default=None, ge=0, le=10)
    target_rir: float | None = Field(default=None, ge=0, le=10)
    rest_seconds: int | None = Field(default=None, ge=0, le=3600)
    tempo: str | None = Field(default=None, max_length=32)
    parameters: dict[str, object] = Field(default_factory=dict)
    progression_policy: dict[str, object] = Field(default_factory=dict)


class PlanExerciseSlotInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    exercise_id: UUID
    exercise_version_no: int | None = Field(default=None, ge=1)
    group_type: Literal["single", "superset", "circuit", "giant_set"] = "single"
    group_id: UUID | None = None
    side_mode: Literal["combined", "per_side", "left_right"] = "combined"
    prescription: PrescriptionInput
    alternatives: list[PlanAlternativeInput] = Field(default_factory=list, max_length=5)


class PlanAlternativeInput(BaseModel):
    """One same-mode backup exercise for the slot, ordered by priority."""

    model_config = ConfigDict(extra="forbid")

    exercise_id: UUID
    rule_json: dict[str, object] = Field(default_factory=dict)
    priority: int = Field(default=1, ge=1, le=99)


class PlanAlternativeResponse(BaseModel):
    exercise_id: UUID
    exercise_name_zh: str
    rule_json: dict[str, object]
    priority: int


class PlanStageBlockInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    purpose: Literal[
        "readiness",
        "general_warmup",
        "mobility",
        "activation_control",
        "movement_prep",
        "power_skill",
        "primary_strength",
        "accessory",
        "local_endurance",
        "conditioning",
        "cooldown_recovery",
    ]
    custom_name: str | None = Field(default=None, max_length=120)
    config: dict[str, object] = Field(default_factory=dict)
    slots: list[PlanExerciseSlotInput] = Field(min_length=1, max_length=30)


class CreatePlanRequest(BaseModel):
    """One saved plan is one executable training template.

    Stages describe the flow *within that training session* (for example
    warm-up, activation, strength and conditioning).  A plan deliberately has
    no weekly-day or nested-session concept.
    """

    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=120)
    goal: dict[str, object] = Field(default_factory=dict)
    # A new canvas can be saved before its first stage/action is added.  It is
    # not executable until a version is published.
    blocks: list[PlanStageBlockInput] = Field(default_factory=list, max_length=20)


class ReplacePlanVersionRequest(BaseModel):
    """Replace the complete contents of one unpublished plan version.

    A full replacement keeps ordering deterministic and avoids a partially
    edited graph when a desktop client crashes halfway through an edit.
    """

    model_config = ConfigDict(extra="forbid")

    base_revision: int = Field(ge=1)
    blocks: list[PlanStageBlockInput] = Field(default_factory=list, max_length=20)


class PublishPlanVersionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    base_revision: int = Field(ge=1)


class PlanSummaryResponse(BaseModel):
    id: UUID
    name: str
    current_version_no: int
    status: Literal["active", "archived"]
    is_published: bool
    revision: int
    block_count: int
    exercise_slot_count: int


class PlanVersionResponse(BaseModel):
    id: UUID
    plan_id: UUID
    version_no: int
    based_on_version_no: int | None
    is_published: bool
    revision: int


class PlanSlotResponse(BaseModel):
    id: UUID
    exercise_id: UUID
    exercise_version_no: int
    exercise_name_zh: str
    group_id: UUID | None
    group_type: str
    side_mode: str
    prescription: PrescriptionInput
    alternatives: list[PlanAlternativeResponse] = Field(default_factory=list)
    sort_order: int


class PlanBlockResponse(BaseModel):
    id: UUID
    purpose: str
    custom_name: str | None
    config: dict[str, object]
    sort_order: int
    slots: list[PlanSlotResponse]


class PlanDetailResponse(PlanSummaryResponse):
    goal: dict[str, object]
    blocks: list[PlanBlockResponse]


class StartWorkoutRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    timezone: str = Field(default="Asia/Shanghai", min_length=1, max_length=80)
    started_at: datetime | None = None


class WorkoutItemResponse(BaseModel):
    id: UUID
    source_slot_id: UUID | None
    exercise_id: UUID
    exercise_version_no: int | None
    exercise_snapshot: dict[str, object]
    prescription_snapshot: dict[str, object]
    sort_order: int
    set_logs: list[SetLogResponse] = Field(default_factory=list)


class WorkoutSessionResponse(BaseModel):
    id: UUID
    source_plan_id: UUID | None
    source_plan_version_no: int | None
    status: Literal["in_progress", "completed", "abandoned"]
    started_at: datetime
    ended_at: datetime | None
    timezone: str
    items: list[WorkoutItemResponse]
    # Stored in the immutable session snapshot so a renamed plan never
    # rewrites the title of a completed workout.
    plan_name: str | None = None


class WorkoutHistoryEntryResponse(BaseModel):
    id: UUID
    status: Literal["in_progress", "completed", "abandoned"]
    started_at: datetime
    ended_at: datetime | None
    timezone: str
    plan_name: str | None
    item_count: int
    completed_set_count: int
    completed_volume_kg: float


class ActiveWorkoutResponse(BaseModel):
    """The one resumable workout a user may have at a time."""

    workout: WorkoutSessionResponse | None = None


class WorkoutHistoryPageResponse(BaseModel):
    entries: list[WorkoutHistoryEntryResponse]
    limit: int
    offset: int


class SetLogInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    set_type: Literal["warmup", "working", "backoff", "drop", "test"] = "working"
    status: Literal["planned", "completed", "skipped", "failed"] = "completed"
    load_kg: float | None = Field(default=None, ge=0, le=2000)
    original_load: float | None = Field(default=None, ge=0, le=5000)
    original_unit: Literal["kg", "lb"] | None = None
    is_per_side: bool = False
    includes_bar: bool | None = None
    reps: int | None = Field(default=None, ge=0, le=1000)
    duration_seconds: int | None = Field(default=None, ge=0, le=86400)
    distance_meters: float | None = Field(default=None, ge=0, le=1000000)
    rpe: float | None = Field(default=None, ge=0, le=10)
    rir: float | None = Field(default=None, ge=0, le=10)
    pain_score: int | None = Field(default=None, ge=0, le=10)
    technique_ok: bool | None = None
    notes: str | None = Field(default=None, max_length=2000)
    performed_at: datetime | None = None


class SyncSetLogPayload(SetLogInput):
    """The set-log envelope that can be safely applied from the offline queue."""

    model_config = ConfigDict(extra="forbid")

    workout_session_id: UUID
    workout_item_id: UUID
    set_number: int = Field(ge=1, le=100)


class SetLogResponse(SetLogInput):
    id: UUID
    set_number: int


class CompleteWorkoutResponse(BaseModel):
    id: UUID
    status: Literal["completed"]
    ended_at: datetime


class GenerateProgressionSuggestionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    workout_item_id: UUID


class SuggestionDecisionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    decision: Literal["accepted", "modified", "dismissed"]


class ProgressionSuggestionResponse(BaseModel):
    id: UUID
    workout_item_id: UUID
    algorithm_version: str
    input_summary: dict[str, object]
    suggestion: dict[str, object]
    rationale: str
    decision: Literal["pending", "accepted", "modified", "dismissed"]
