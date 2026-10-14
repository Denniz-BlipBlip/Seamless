import numpy as np
from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def _frame(seed: int) -> dict:
    rng = np.random.default_rng(seed)
    return {
        "skin_rgb": np.clip(rng.normal([198, 150, 125], 3, (80, 3)), 0, 255).astype(int).tolist(),
        "white_rgb": [[200, 200, 200]] * 10,
        "hair_rgb": [40, 30, 25],
        "eye_rgb": [90, 60, 40],
    }


def _payload(count: int = 5, consent: bool = True) -> dict:
    return {"frames": [_frame(i) for i in range(count)], "consent_confirmed": consent}


def test_frames_endpoint_returns_a_season() -> None:
    response = client.post("/v1/profile/analyze-frames", json=_payload())
    assert response.status_code == 200
    body = response.json()
    assert body["color_season"] in {"Spring", "Summer", "Autumn", "Winter"}
    assert body["model_version"] == "color-lab-frames-0.1.0"
    assert len(body["accessories"]) == 4
    assert 0 <= body["confidence"] <= 1


def test_frames_endpoint_validation() -> None:
    assert client.post("/v1/profile/analyze-frames", json=_payload(count=2)).status_code == 422
    assert client.post("/v1/profile/analyze-frames", json=_payload(consent=False)).status_code == 422
    bad = _payload()
    bad["frames"][0]["hair_rgb"] = [300, 0, 0]
    assert client.post("/v1/profile/analyze-frames", json=bad).status_code == 422
