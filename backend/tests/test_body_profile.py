import math

from fastapi.testclient import TestClient

from app.body_profile import ellipse_circumference
from app.main import app

client = TestClient(app)


def _payload(**overrides):
    body = {
        "height_cm": 165,
        "front_widths_cm": {"chest": 32, "waist": 26, "high_hip": 30, "hip": 35},
        "side_depths_cm": {"chest": 22, "waist": 19, "high_hip": 22, "hip": 25},
        "back_widths_cm": {"chest": 31.5, "waist": 26.5, "high_hip": 30, "hip": 35.5},
        "shoulder_cm": 38,
        "hip_to_ankle_cm": 78,
        "warnings": [],
        "consent_confirmed": True,
    }
    body.update(overrides)
    return body


def test_ellipse_circumference_matches_circle() -> None:
    assert math.isclose(ellipse_circumference(20, 20), math.pi * 20, rel_tol=1e-6)


def test_profile_returns_all_measurements() -> None:
    response = client.post("/v1/body-scan/profile", json=_payload())
    assert response.status_code == 200
    body = response.json()
    assert set(body["measurements"]) == {
        "height", "neck", "shoulder", "chest", "underbust", "waist",
        "high_hip", "hip", "sleeve", "wrist", "inseam",
    }
    assert 80 < body["measurements"]["chest"] < 95
    assert 65 < body["measurements"]["waist"] < 80
    assert 90 < body["measurements"]["hip"] < 110
    for key in ("chest", "waist", "hip", "height"):
        assert key in body["displayable_measurements"]
    assert "wrist" not in body["displayable_measurements"]


def test_missing_side_level_uses_typical_depth_and_lowers_confidence() -> None:
    full = client.post("/v1/body-scan/profile", json=_payload()).json()
    partial = client.post(
        "/v1/body-scan/profile",
        json=_payload(side_depths_cm={"waist": 19, "hip": 25}),
    ).json()
    assert partial["measurement_confidence"]["chest"] < full["measurement_confidence"]["chest"]
    assert any("side photo" in w for w in partial["quality_warnings"])


def test_works_without_back_photo() -> None:
    response = client.post("/v1/body-scan/profile", json=_payload(back_widths_cm={}))
    assert response.status_code == 200


def test_too_little_torso_data_is_rejected() -> None:
    response = client.post(
        "/v1/body-scan/profile",
        json=_payload(front_widths_cm={"chest": 32}, back_widths_cm={}),
    )
    assert response.status_code == 422


def test_rejects_unknown_level_bad_range_and_missing_consent() -> None:
    assert client.post(
        "/v1/body-scan/profile",
        json=_payload(front_widths_cm={"belly": 30}),
    ).status_code == 422
    assert client.post(
        "/v1/body-scan/profile",
        json=_payload(front_widths_cm={"chest": 200, "waist": 26, "hip": 35}),
    ).status_code == 422
    assert client.post(
        "/v1/body-scan/profile", json=_payload(consent_confirmed=False)
    ).status_code == 422
