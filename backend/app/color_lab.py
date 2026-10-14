"""Lab-based color features for personal-color analysis.

Pure functions, no I/O. Thresholds are starting values to tune against
analyst-labelled data; they are not validated.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

# Undertone: skin hue angle in CIELAB (degrees). Higher = more yellow (warm),
# lower = more pink/red (cool). Tune on real data.
NEUTRAL_HUE_LOW = 52.0
NEUTRAL_HUE_HIGH = 58.0

# Depth from L*.
LIGHT_L = 65.0
DEEP_L = 45.0

# Clarity (chroma): above = clear/bright, below = soft/muted.
CLEAR_CHROMA = 24.0

# Frames agree when their spread stays under these limits.
MAX_L_SPREAD = 6.0
MAX_HUE_SPREAD = 6.0

_D65 = np.array([0.95047, 1.0, 1.08883])


@dataclass(frozen=True)
class ColorFeatures:
    lightness: float
    a: float
    b: float
    chroma: float
    hue: float

    @property
    def undertone(self) -> str:
        if self.hue < NEUTRAL_HUE_LOW:
            return "cool"
        if self.hue > NEUTRAL_HUE_HIGH:
            return "warm"
        return "neutral"

    @property
    def depth(self) -> str:
        if self.lightness >= LIGHT_L:
            return "light"
        if self.lightness <= DEEP_L:
            return "deep"
        return "medium"

    @property
    def clarity(self) -> str:
        return "clear" if self.chroma >= CLEAR_CHROMA else "soft"


def srgb_to_lab(rgb: np.ndarray) -> np.ndarray:
    """Convert sRGB values (0-255, shape (...,3)) to CIELAB (D65)."""
    rgb = np.asarray(rgb, dtype=np.float64) / 255.0
    linear = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    matrix = np.array(
        [
            [0.4124564, 0.3575761, 0.1804375],
            [0.2126729, 0.7151522, 0.0721750],
            [0.0193339, 0.1191920, 0.9503041],
        ]
    )
    xyz = linear @ matrix.T / _D65
    f = np.where(xyz > 216 / 24389, np.cbrt(xyz), (24389 / 27 * xyz + 16) / 116)
    lightness = 116 * f[..., 1] - 16
    a = 500 * (f[..., 0] - f[..., 1])
    b = 200 * (f[..., 1] - f[..., 2])
    return np.stack([lightness, a, b], axis=-1)


def white_balance_gains(reference_rgb: np.ndarray) -> np.ndarray:
    """Per-channel gains that turn a known-neutral reference into gray.

    Use the whites of the eyes, paper, or the gray-world mean of the scene.
    """
    reference = np.asarray(reference_rgb, dtype=np.float64).reshape(-1, 3)
    mean = np.maximum(reference.mean(axis=0), 1.0)
    return mean.mean() / mean


def apply_gains(rgb: np.ndarray, gains: np.ndarray) -> np.ndarray:
    return np.clip(np.asarray(rgb, dtype=np.float64) * gains, 0, 255)


def color_cast(reference_rgb: np.ndarray) -> float:
    """How far a supposedly neutral reference is from gray (0 = none).

    Measured as Lab chroma of the reference's mean color.
    """
    mean = np.asarray(reference_rgb, dtype=np.float64).reshape(-1, 3).mean(axis=0)
    _, a, b = srgb_to_lab(mean)
    return float(math.hypot(a, b))


def skin_features(pixels: np.ndarray, gains: np.ndarray | None = None) -> ColorFeatures:
    """Robust Lab summary of skin pixels (shape (N,3), sRGB 0-255).

    Drops the darkest and brightest 15% (shadows, highlights) and takes the
    median of the rest.
    """
    pixels = np.asarray(pixels, dtype=np.float64).reshape(-1, 3)
    if pixels.shape[0] < 50:
        raise ValueError("Not enough skin pixels to measure.")
    if gains is not None:
        pixels = apply_gains(pixels, gains)
    lab = srgb_to_lab(pixels)
    low, high = np.percentile(lab[:, 0], (15, 85))
    kept = lab[(lab[:, 0] >= low) & (lab[:, 0] <= high)]
    if kept.shape[0] == 0:
        kept = lab
    lightness, a, b = np.median(kept, axis=0)
    return ColorFeatures(
        lightness=float(lightness),
        a=float(a),
        b=float(b),
        chroma=float(math.hypot(a, b)),
        hue=float(math.degrees(math.atan2(b, a)) % 360),
    )


def combine_frames(frames: list[ColorFeatures]) -> tuple[ColorFeatures, bool]:
    """Median of several frames, plus whether they agree with each other."""
    if not frames:
        raise ValueError("At least one frame is required.")
    lightness = [f.lightness for f in frames]
    hue = [f.hue for f in frames]
    merged_a = float(np.median([f.a for f in frames]))
    merged_b = float(np.median([f.b for f in frames]))
    merged = ColorFeatures(
        lightness=float(np.median(lightness)),
        a=merged_a,
        b=merged_b,
        chroma=math.hypot(merged_a, merged_b),
        hue=math.degrees(math.atan2(merged_b, merged_a)) % 360,
    )
    consistent = (
        len(frames) >= 3
        and max(lightness) - min(lightness) <= MAX_L_SPREAD
        and max(hue) - min(hue) <= MAX_HUE_SPREAD
    )
    return merged, consistent
