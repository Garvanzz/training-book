from types import SimpleNamespace
from uuid import uuid4

import pytest

from app.api.routes import library
from app.api.schemas import CreatePlanRequest, ReplacePlanVersionRequest
from app.main import app


def test_plan_version_routes_are_registered() -> None:
    paths = app.openapi()["paths"]

    assert "post" in paths["/v1/plans/{plan_id}/versions"]
    assert "put" in paths["/v1/plans/{plan_id}/versions/{version_no}"]
    assert "post" in paths["/v1/plans/{plan_id}/versions/{version_no}/publish"]
    assert "/v1/workouts/from-plan/{plan_id}" in paths
    assert "/v1/workouts/from-template/{template_id}" not in paths


def test_plan_contract_is_one_training_template_with_optional_draft_content() -> None:
    empty_canvas = CreatePlanRequest(name="上肢力量")
    assert empty_canvas.blocks == []
    assert empty_canvas.model_dump().get("sessions") is None

    replacement = ReplacePlanVersionRequest(base_revision=1)
    assert replacement.blocks == []

    with pytest.raises(ValueError):
        CreatePlanRequest(
            name="错误的训练日模型",
            sessions=[],
        )


def test_plan_stage_contract_keeps_each_action_prescription_independent() -> None:
    exercise_id = uuid4()
    request = CreatePlanRequest.model_validate(
        {
            "name": "深蹲专项",
            "blocks": [
                {
                    "purpose": "primary_strength",
                    "slots": [
                        {
                            "exercise_id": str(exercise_id),
                            "prescription": {
                                "prescription_type": "rep_range",
                                "set_count": 4,
                                "rep_min": 4,
                                "rep_max": 6,
                                "target_load_kg": 100,
                            },
                        }
                    ],
                }
            ],
        }
    )
    assert request.blocks[0].slots[0].prescription.target_load_kg == 100


def test_workout_history_route_is_registered() -> None:
    paths = app.openapi()["paths"]

    assert "get" in paths["/v1/workouts/history"]
    assert "get" in paths["/v1/workouts/active"]
    assert "get" in paths["/v1/workouts/{workout_session_id}"]
    assert "post" in paths["/v1/workouts/{workout_session_id}/abandon"]


def test_workout_detail_contract_exposes_immutable_plan_name_and_set_logs() -> None:
    schemas = app.openapi()["components"]["schemas"]

    assert "plan_name" in schemas["WorkoutSessionResponse"]["properties"]
    assert "set_logs" in schemas["WorkoutItemResponse"]["properties"]
    assert schemas["ActiveWorkoutResponse"]["properties"]["workout"]["anyOf"]


def test_exercise_draft_lifecycle_routes_are_registered() -> None:
    paths = app.openapi()["paths"]

    assert "post" in paths["/v1/library/exercises/{exercise_id}/versions/draft"]
    assert "delete" in paths["/v1/library/media/{media_id}"]
    assert "delete" in paths["/v1/library/drafts/{exercise_id}/versions/{version_no}"]


def test_local_media_cleanup_refuses_paths_outside_the_media_root(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(library, "get_settings", lambda: SimpleNamespace(local_media_root=tmp_path))

    assert library._local_media_path("local/exercise/video.mp4") == tmp_path / "local/exercise/video.mp4"
    assert library._local_media_path("local/../../outside.mp4") is None
    assert library._local_media_path("oss/private/video.mp4") is None


def test_registration_and_me_routes_are_registered() -> None:
    paths = app.openapi()["paths"]

    assert "post" in paths["/v1/auth/register"]
    assert "get" in paths["/v1/auth/registration-status"]
    assert "get" in paths["/v1/auth/me"]


def test_registration_response_contract_issues_a_session() -> None:
    schemas = app.openapi()["components"]["schemas"]

    assert "display_name" in schemas["RegisterRequest"]["properties"]
    assert schemas["RegisterRequest"]["properties"]["display_name"]["default"] == "训练者"
    assert "enabled" in schemas["RegistrationStatusResponse"]["properties"]
    assert "is_owner" in schemas["AuthMeResponse"]["properties"]


def test_registration_status_reflects_config_switch(monkeypatch) -> None:
    import asyncio
    from types import SimpleNamespace as NS

    from app.api.routes import auth as auth_routes

    monkeypatch.setattr(auth_routes, "get_settings", lambda: NS(registration_enabled=True))
    status = asyncio.run(auth_routes.registration_status())
    assert status.enabled is True

    monkeypatch.setattr(auth_routes, "get_settings", lambda: NS(registration_enabled=False))
    status = asyncio.run(auth_routes.registration_status())
    assert status.enabled is False


def test_deprecate_and_suggestion_decision_routes_are_registered() -> None:
    paths = app.openapi()["paths"]

    assert "post" in paths["/v1/library/exercises/{exercise_id}/deprecate"]
    assert "patch" in paths["/v1/progression/suggestions/{suggestion_id}"]
