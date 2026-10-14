"""Shared measurement names and limits for the guided body scan."""

from __future__ import annotations

MEASUREMENT_NAMES = (
    "height",
    "neck",
    "shoulder",
    "chest",
    "underbust",
    "waist",
    "high_hip",
    "hip",
    "sleeve",
    "wrist",
    "inseam",
)

MEASUREMENT_LIMITS = {
    "height": (120.0, 230.0),
    "neck": (20.0, 70.0),
    "shoulder": (25.0, 75.0),
    "chest": (55.0, 190.0),
    "underbust": (50.0, 170.0),
    "waist": (45.0, 190.0),
    "high_hip": (55.0, 200.0),
    "hip": (60.0, 210.0),
    "sleeve": (35.0, 90.0),
    "wrist": (10.0, 35.0),
    "inseam": (45.0, 110.0),
}
