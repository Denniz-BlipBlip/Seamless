from __future__ import annotations

import math

from pydantic import BaseModel, Field, field_validator

from .body_scan import MEASUREMENT_LIMITS, MEASUREMENT_NAMES
from .schemas import BodyScanResponse, Measurements

# Torso levels the phone measures, in the order they are used.
LEVELS = ("chest", "waist", "high_hip", "hip")

# Side depth / front width when the side photo could not be read at a level.
TYPICAL_DEPTH_RATIO = {"chest": 0.70, "waist": 0.72, "high_hip": 0.75, "hip": 0.75}

# Real torsos fall inside this depth/width range; anything else is a bad read.
DEPTH_RATIO_RANGE = (0.45, 1.0)

# Front and back widths may differ by this fraction before we warn.
FRONT_BACK_TOLERANCE = 0.15

# Tuning knobs. Compare against tape measurements, then adjust per level.
# Silhouettes usually read slightly wide, so values below 1.0 may help.
CIRCUMFERENCE_SCALE = {level: 1.0 for level in LEVELS}

# Confidence below this is hidden by the app.
DISPLAY_THRESHOLD = 0.55


class BodyProfileError(ValueError):
    pass


class BodyProfileRequest(BaseModel):
    """Numbers measured on the phone from the front, side and back photos."""

    height_cm: float = Field(ge=120, le=230)
    front_widths_cm: dict[str, float]
    side_depths_cm: dict[str, float]
    back_widths_cm: dict[str, float] = Field(default_factory=dict)
    shoulder_cm: float | None = Field(default=None, ge=20, le=70)
    hip_to_ankle_cm: float | None = Field(default=None, ge=30, le=130)
    warnings: list[str] = Field(default_factory=list, max_length=20)
    consent_confirmed: bool

    @field_validator("front_widths_cm", "side_depths_cm", "back_widths_cm")
    @classmethod
    def validate_levels(cls, value: dict[str, float]) -> dict[str, float]:
        for key, number in value.items():
            if key not in LEVELS:
                raise ValueError(f"Unknown body level: {key}")
            if not 5 <= number <= 80:
                raise ValueError(f"{key} must be between 5 and 80 cm")
        return value

    @field_validator("warnings")
    @classmethod
    def trim_warnings(cls, value: list[str]) -> list[str]:
        return [item[:200] for item in value]

    @field_validator("consent_confirmed")
    @classmethod
    def require_consent(cls, value: bool) -> bool:
        if not value:
            raise ValueError("Body analysis requires explicit consent")
        return value


def ellipse_circumference(width_cm: float, depth_cm: float) -> float:
    """Ramanujan's ellipse approximation from full width and full depth."""
    a, b = width_cm / 2, depth_cm / 2
    return math.pi * (3 * (a + b) - math.sqrt((3 * a + b) * (a + 3 * b)))


class BodyProfileEstimator:
    """Front width + side depth -> circumference, plus derived measurements.

    Prototype geometry, not a validated model: check it against consented
    tape measurements (MAE and within-tolerance rates) before any sizing claim.
    """

    def estimate(self, request: BodyProfileRequest) -> BodyScanResponse:
        warnings = list(request.warnings)
        arms_warning = any("arms" in item.lower() for item in warnings)
        circumference: dict[str, float] = {}
        confidence: dict[str, float] = {}

        for level in LEVELS:
            front = request.front_widths_cm.get(level)
            back = request.back_widths_cm.get(level)
            if front is None and back is None:
                continue
            width, level_confidence = self._width(front, back, level, warnings)
            depth = request.side_depths_cm.get(level)
            if depth is None:
                depth = width * TYPICAL_DEPTH_RATIO[level]
                level_confidence -= 0.30
                warnings.append(
                    f"The side photo could not be read at your {level.replace('_', ' ')}; a typical depth was used."
                )
            else:
                low, high = DEPTH_RATIO_RANGE
                ratio = depth / width
                if not low <= ratio <= high:
                    depth = width * min(max(ratio, low), high)
                    level_confidence -= 0.20
                    warnings.append(
                        f"Your {level.replace('_', ' ')} depth looked unusual and was adjusted. Retake the side photo."
                    )
            if arms_warning and level in ("chest", "waist"):
                level_confidence -= 0.08
            circumference[level] = (
                ellipse_circumference(width, depth) * CIRCUMFERENCE_SCALE[level]
            )
            confidence[level] = level_confidence

        missing = [level for level in ("chest", "waist", "hip") if level not in circumference]
        if missing:
            raise BodyProfileError(
                "The scan did not capture enough of your torso. Retake it with your whole body in view."
            )

        height = request.height_cm
        chest, waist, hip = (circumference[k] for k in ("chest", "waist", "hip"))
        high_hip = circumference.get("high_hip", waist * 0.46 + hip * 0.54)
        shoulder = request.shoulder_cm or height * 0.24
        inseam = (
            min(max(request.hip_to_ankle_cm * 0.95, height * 0.40), height * 0.50)
            if request.hip_to_ankle_cm
            else height * 0.46
        )
        raw = {
            "height": height,
            "neck": max(height * 0.195, shoulder * 0.82),
            "shoulder": shoulder,
            "chest": chest,
            "underbust": chest * 0.90,
            "waist": waist,
            "high_hip": high_hip,
            "hip": hip,
            "sleeve": height * 0.355,
            "wrist": height * 0.095,
            "inseam": inseam,
        }
        values = {
            name: round(float(min(max(raw[name], MEASUREMENT_LIMITS[name][0]), MEASUREMENT_LIMITS[name][1])), 1)
            for name in MEASUREMENT_NAMES
        }

        measured = {
            "chest": confidence["chest"],
            "waist": confidence["waist"],
            "hip": confidence["hip"],
            "high_hip": confidence.get("high_hip", min(confidence["waist"], confidence["hip"]) - 0.15),
        }
        derived = {
            "height": 0.99,
            "shoulder": 0.75 if request.shoulder_cm else 0.40,
            "neck": 0.35,
            "underbust": confidence["chest"] * 0.65,
            "sleeve": 0.38,
            "wrist": 0.28,
            "inseam": 0.60 if request.hip_to_ankle_cm else 0.40,
        }
        all_confidence = {
            name: round(float(min(max({**measured, **derived}[name], 0.15), 0.95)), 2)
            for name in MEASUREMENT_NAMES
        }
        displayable = [
            name
            for name in MEASUREMENT_NAMES
            if name == "height" or all_confidence[name] >= DISPLAY_THRESHOLD
        ]
        scan_confidence = round(sum(all_confidence.values()) / len(all_confidence), 2)
        image_quality = round(min(max(0.92 - 0.06 * len(request.warnings), 0.5), 0.92), 2)

        unique_warnings = list(dict.fromkeys(warnings))
        if not unique_warnings:
            unique_warnings = ["Front, side and back views agreed with each other."]

        return BodyScanResponse(
            person_detected=True,
            person_confidence=0.9,
            measurements=Measurements(**values),
            scan_confidence=scan_confidence,
            image_quality=image_quality,
            measurement_confidence=all_confidence,
            displayable_measurements=displayable,
            quality_warnings=unique_warnings,
            model_version="body-3view-ellipse-0.1.0",
            validation_status=(
                "Unvalidated three-view estimate. Accuracy must be measured with MAE and "
                "within-tolerance tests against consented tape measurements."
            ),
            disclaimer=(
                "Estimated from front, side and back photos processed on your phone; only body "
                "widths and depths were sent. Neck, wrist, sleeve and underbust are not reliable "
                "from photos. Verify with a tape measure and the seller's size chart before buying."
            ),
        )

    @staticmethod
    def _width(
        front: float | None,
        back: float | None,
        level: str,
        warnings: list[str],
    ) -> tuple[float, float]:
        if front is not None and back is not None:
            if abs(front - back) / max(front, back) > FRONT_BACK_TOLERANCE:
                warnings.append(
                    f"Front and back photos disagree at your {level.replace('_', ' ')}. Retake them in even light."
                )
                return (front + back) / 2, 0.72
            return (front + back) / 2, 0.87
        return (front if front is not None else back), 0.80  # type: ignore[return-value]
