import numpy as np
import pytest

from app.color_frames import ColorFramesError, analyze_frames, choose_season
from app.color_lab import ColorFeatures


def _f(lightness, hue, chroma):
    import math
    return ColorFeatures(lightness, chroma * math.cos(math.radians(hue)),
                         chroma * math.sin(math.radians(hue)), chroma, hue)


def _frame(seed, skin=(198, 150, 125), cast=(1, 1, 1), white=200, hair=(40, 30, 25), eye=(90, 60, 40)):
    rng = np.random.default_rng(seed)
    c = np.array(cast)
    return {
        "skin_rgb": np.clip(rng.normal(skin, 3, (200, 3)) * c, 0, 255).tolist(),
        "white_rgb": np.clip(np.full((20, 3), white) * c, 0, 255).tolist(),
        "hair_rgb": np.clip(np.array(hair) * c, 0, 255).tolist(),
        "eye_rgb": np.clip(np.array(eye) * c, 0, 255).tolist(),
    }


def test_season_mapping() -> None:
    assert choose_season(_f(70, 65, 30), None) == "Spring"
    assert choose_season(_f(40, 65, 20), None) == "Autumn"
    assert choose_season(_f(70, 45, 15), None) == "Summer"
    assert choose_season(_f(40, 45, 30), None) == "Winter"
    assert choose_season(_f(70, 65, 15), 45) == "Spring"  # high contrast reads clear


def test_good_capture_is_consistent_and_confident() -> None:
    out = analyze_frames([_frame(i) for i in range(5)])
    assert out["consistent"] and out["white_balanced"]
    assert out["confidence"] > 0.75
    assert out["contrast"] is not None


def test_lighting_cast_does_not_change_the_answer() -> None:
    neutral = analyze_frames([_frame(i) for i in range(5)])
    warm = analyze_frames([_frame(i, cast=(1.08, 1.0, 0.82)) for i in range(5)])
    assert abs(neutral["hue"] - warm["hue"]) < 4
    assert neutral["season"] == warm["season"]


def test_clipped_white_reference_is_rejected() -> None:
    out = analyze_frames([_frame(i, white=255) for i in range(5)])
    assert not out["white_balanced"]
    assert any("Eye whites" in w for w in out["warnings"])


def test_inconsistent_frames_cap_confidence() -> None:
    frames = [_frame(0), _frame(1, skin=(150, 110, 90)), _frame(2), _frame(3, skin=(225, 180, 150))]
    out = analyze_frames(frames)
    assert not out["consistent"]
    assert out["confidence"] <= 0.55


def test_frame_count_and_skin_validation() -> None:
    with pytest.raises(ColorFramesError):
        analyze_frames([_frame(0), _frame(1)])
    bad = [_frame(i) for i in range(3)]
    bad[0]["skin_rgb"] = [[200, 150, 120]] * 10
    with pytest.raises(ColorFramesError):
        analyze_frames(bad)
