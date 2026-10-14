"""Multi-frame personal-color analysis from colors sampled on the phone.

The phone sends small lists of RGB samples (skin, eye whites, hair, iris),
never a photo. This module balances white, measures Lab features per frame,
checks that frames agree, and picks a season.

Thresholds are starting values, not validated against analyst labels.
"""

from __future__ import annotations

import numpy as np

from .color_lab import (
    ColorFeatures,
    apply_gains,
    color_cast,
    combine_frames,
    skin_features,
    srgb_to_lab,
)

MIN_FRAMES = 3
MAX_FRAMES = 12

# A usable white reference is bright but not clipped.
WHITE_MIN_MEAN = 110.0
WHITE_MAX_CHANNEL = 248.0
# Brightness the eye whites are mapped to. Fixing it also evens out exposure
# between frames, so depth (L*) does not drift with camera brightness.
REFERENCE_LEVEL = 200.0
# Eye whites are not perfectly neutral, so limit how hard we correct.
GAIN_RANGE = (0.7, 1.4)
# Lab chroma of the reference above which lighting has a strong color cast.
STRONG_CAST = 25.0
# Skin-vs-hair lightness gap (L*) that counts as high contrast.
HIGH_CONTRAST = 40.0


class ColorFramesError(ValueError):
    pass


def _usable_reference(white: np.ndarray | None) -> bool:
    if white is None or len(white) < 5:
        return False
    mean = white.mean(axis=0)
    return bool(mean.mean() >= WHITE_MIN_MEAN and mean.max() <= WHITE_MAX_CHANNEL)


def choose_season(features: ColorFeatures, contrast: float | None) -> str:
    clear = features.clarity == "clear" or (contrast is not None and contrast >= HIGH_CONTRAST)
    depth = features.depth
    undertone = features.undertone
    if undertone == "warm":
        return "Autumn" if depth == "deep" or not clear else "Spring"
    if undertone == "cool":
        return "Winter" if depth == "deep" or clear else "Summer"
    # Neutral undertone: decide from depth and clarity.
    if clear:
        return "Spring" if depth == "light" else "Winter"
    return "Autumn" if depth == "deep" else "Summer"


def analyze_frames(frames: list[dict]) -> dict:
    """Analyse 3-12 frames. Each frame is a dict with ``skin_rgb`` (N x 3) and
    optional ``white_rgb`` (N x 3), ``hair_rgb`` (3) and ``eye_rgb`` (3)."""
    if not MIN_FRAMES <= len(frames) <= MAX_FRAMES:
        raise ColorFramesError(
            f"Send between {MIN_FRAMES} and {MAX_FRAMES} frames for a reliable result."
        )

    per_frame: list[ColorFeatures] = []
    sample_colors: list[np.ndarray] = []
    contrasts: list[float] = []
    casts: list[float] = []
    reference_frames = 0
    detail_frames = 0

    for frame in frames:
        skin = np.asarray(frame.get("skin_rgb", []), dtype=np.float64).reshape(-1, 3)
        white_raw = frame.get("white_rgb")
        white = (
            np.asarray(white_raw, dtype=np.float64).reshape(-1, 3)
            if white_raw is not None and len(white_raw)
            else None
        )
        gains = None
        if _usable_reference(white):
            gains = np.clip(REFERENCE_LEVEL / np.maximum(white.mean(axis=0), 1.0), *GAIN_RANGE)
            casts.append(color_cast(white))
            reference_frames += 1
        try:
            features = skin_features(skin, gains)
        except ValueError as error:
            raise ColorFramesError(
                "Not enough clear skin was sampled. Face the camera in even daylight."
            ) from error
        per_frame.append(features)
        balanced = apply_gains(skin, gains) if gains is not None else skin
        sample_colors.append(np.median(balanced, axis=0))

        hair = frame.get("hair_rgb")
        eye = frame.get("eye_rgb")
        if hair is not None and eye is not None:
            detail_frames += 1
        if hair is not None:
            hair_rgb = np.asarray(hair, dtype=np.float64)
            if gains is not None:
                hair_rgb = apply_gains(hair_rgb, gains)
            contrasts.append(abs(features.lightness - float(srgb_to_lab(hair_rgb)[0])))

    merged, consistent = combine_frames(per_frame)
    contrast = float(np.median(contrasts)) if contrasts else None
    reference_share = reference_frames / len(frames)
    median_cast = float(np.median(casts)) if casts else None

    if median_cast is None:
        lighting = 0.5
    else:
        lighting = 0.9 - 0.6 * min(max((median_cast - 10) / 30, 0.0), 1.0)

    warnings: list[str] = []
    if reference_share < 0.6:
        warnings.append(
            "Eye whites were not clear enough to correct the lighting. "
            "Open your eyes wide and avoid glare."
        )
    if median_cast is not None and median_cast > STRONG_CAST:
        warnings.append("The light has a strong color cast. Move to indirect daylight.")
    if not consistent:
        warnings.append("Frames disagreed with each other. Hold still in even light and retake.")
    if contrast is None:
        warnings.append("Hair color was not read, so contrast was not used.")
    if not warnings:
        warnings.append("Lighting and frames agreed. Good capture.")

    confidence = (
        0.35
        + (0.25 if consistent else 0.0)
        + 0.15 * reference_share
        + (0.10 if detail_frames / len(frames) >= 0.6 else 0.0)
        + 0.15 * lighting
    )
    confidence = min(confidence, 0.90)
    if not consistent:
        confidence = min(confidence, 0.55)

    sample = np.clip(np.median(np.stack(sample_colors), axis=0), 0, 255)
    return {
        "season": choose_season(merged, contrast),
        "undertone": merged.undertone,
        "depth": merged.depth,
        "clarity": merged.clarity,
        "lightness": round(merged.lightness, 1),
        "hue": round(merged.hue, 1),
        "chroma": round(merged.chroma, 1),
        "contrast": round(contrast, 1) if contrast is not None else None,
        "consistent": consistent,
        "white_balanced": reference_share >= 0.6,
        "confidence": round(confidence, 2),
        "lighting_quality": round(lighting, 2),
        "warnings": warnings,
        "sampled_color": "#{:02X}{:02X}{:02X}".format(*(int(v) for v in sample)),
    }


def to_response_fields(result: dict) -> dict:
    """Shape the analysis like AppearanceAnalysisResponse (same app result card)."""
    from .ai_engine import PALETTES
    from .appearance_analysis import _ACCESSORIES

    season = result["season"]
    palette = PALETTES[season]
    return {
        "color_season": season,
        "complexion_direction": (
            f"{result['undertone'].title()} · {result['depth']} · {result['clarity']}"
        ),
        "sampled_color": result["sampled_color"],
        "confidence": result["confidence"],
        "lighting_quality": result["lighting_quality"],
        "quality_warnings": result["warnings"],
        "palette": palette["palette"],
        "metals": palette["metals"],
        "accessories": [{"name": n, "reason": r} for n, r in _ACCESSORIES[season]],
        "styling_notes": [
            f"Start with {palette['metals'][0]} near the face.",
            "Repeat one accessory color in the shoes, bag, or outer layer.",
            "Check the palette against a second photo before buying a statement piece.",
        ],
        "model_version": "color-lab-frames-0.1.0",
        "disclaimer": (
            "Aesthetic guidance from colors sampled on your phone, not identity, ethnicity, "
            "health, or biometric analysis. No photo was sent. Lighting, makeup and camera "
            "white balance can change the result. Thresholds are unvalidated."
        ),
    }
