#!/usr/bin/env python3
"""Check Forma v2 theme tokens and the accent asset without Xcode."""
import json
import math
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
theme = (ROOT / "FormaSync/UI/Theme.swift").read_text()
expected = {
    "bg": "0x14110E",
    "surface": "0x1B1714",
    "surface2": "0x231E1A",
    "border": "0x2E2823",
    "border2": "0x3A332D",
    "text": "0xF4EEE5",
    "muted": "0xCDC3B6",
    "dim": "0xA79D91",
    "accent": "0xE8C547",
    "onAccent": "0x171710",
    "ok": "0x8FBF8A",
    "fail": "0xE07A5F",
    "info": "0x8FB3D9",
}
for name, value in expected.items():
    matches = re.findall(
        rf"static\s+let\s+{name}\s*=\s*Color\(hex:\s*(0x[0-9A-Fa-f]+)\)", theme
    )
    assert matches == [value], f"{name}: expected {value}, got {matches}"
assert "0x0c0c0c" not in theme.lower(), "Legacy cold background remains"

asset = json.loads((ROOT / "FormaSync/Assets.xcassets/AccentColor.colorset/Contents.json").read_text())
for entry in asset["colors"]:
    color = entry["color"]
    assert color["color-space"] == "srgb"
    components = color["components"]
    for name, value in {"red": 232, "green": 197, "blue": 71, "alpha": 255}.items():
        assert math.isclose(float(components[name]) * 255, value, abs_tol=1e-12, rel_tol=0), name
print("PASS: Forma v2 tokens, preserved status colors, and exact accent RGB 232/197/71")
