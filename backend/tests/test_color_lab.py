import numpy as np
import pytest

from app.color_lab import (
    ColorFeatures,
    apply_gains,
    color_cast,
    combine_frames,
    skin_features,
    srgb_to_lab,
    white_balance_gains,
)


def test_lab_reference_values() -> None:
    white = srgb_to_lab(np.array([255, 255, 255]))
    black = srgb_to_lab(np.array([0, 0, 0]))
    assert white[0] == pytest.approx(100, abs=0.1)
    assert abs(white[1]) < 0.1 and abs(white[2]) < 0.1
    assert black[0] == pytest.approx(0, abs=0.1)
    red = srgb_to_lab(np.array([255, 0, 0]))
    assert red[0] == pytest.approx(53.2, abs=0.5)
    assert red[1] == pytest.approx(80.1, abs=0.5)


def test_white_balance_removes_a_color_cast() -> None:
    warm_white = np.array([[250, 235, 200]] * 20)
    assert color_cast(warm_white) > 10
    gains = white_balance_gains(warm_white)
    fixed = apply_gains(warm_white, gains)
    assert color_cast(fixed) < 1


def test_same_skin_under_warm_light_matches_after_balance() -> None:
    rng = np.random.default_rng(1)
    skin = np.clip(rng.normal([198, 150, 125], 4, (400, 3)), 0, 255)
    cast = np.array([1.08, 1.0, 0.82])
    lit = np.clip(skin * cast, 0, 255)
    white = np.array([[200, 200, 200]] * 20) * cast
    raw = skin_features(lit)
    fixed = skin_features(lit, white_balance_gains(np.clip(white, 0, 255)))
    truth = skin_features(skin)
    assert abs(fixed.hue - truth.hue) < abs(raw.hue - truth.hue)
    assert abs(fixed.hue - truth.hue) < 3


def test_undertone_depth_clarity_labels() -> None:
    warm = ColorFeatures(lightness=70, a=10, b=22, chroma=24.2, hue=65.5)
    cool = ColorFeatures(lightness=40, a=16, b=15, chroma=21.9, hue=43.2)
    assert warm.undertone == "warm" and warm.depth == "light" and warm.clarity == "clear"
    assert cool.undertone == "cool" and cool.depth == "deep" and cool.clarity == "soft"


def test_too_few_pixels_rejected() -> None:
    with pytest.raises(ValueError):
        skin_features(np.zeros((10, 3)))


def _frame(lightness: float, hue: float) -> ColorFeatures:
    import math

    a = 25 * math.cos(math.radians(hue))
    b = 25 * math.sin(math.radians(hue))
    return ColorFeatures(lightness, a, b, 25, hue)


def test_frames_agree_when_close() -> None:
    merged, ok = combine_frames([_frame(60, 55), _frame(61, 56), _frame(59, 54)])
    assert ok
    assert merged.lightness == pytest.approx(60)


def test_frames_disagree_when_lighting_shifts() -> None:
    _, ok = combine_frames([_frame(60, 55), _frame(72, 55), _frame(58, 55)])
    assert not ok


def test_needs_three_frames_to_be_consistent() -> None:
    _, ok = combine_frames([_frame(60, 55), _frame(60, 55)])
    assert not ok
