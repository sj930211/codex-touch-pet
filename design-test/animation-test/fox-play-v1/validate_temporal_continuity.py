#!/usr/bin/env python3
"""Fail when adjacent fox action frames are too far apart for Touch Bar playback."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent
REPORT = ROOT / "qa" / "continuity.json"

# At 5 px wide on a Touch Bar, a frame pair above this threshold reads as a
# slide change instead of motion. This is deliberately strict for the first
# production pass.
MAX_ADJACENT_DIFFERENCE = 0.16


def main() -> None:
    report = json.loads(REPORT.read_text())
    failures: list[str] = []
    for action, state in report["states"].items():
        differences = state["adjacent_difference"]
        worst = max(differences)
        if worst > MAX_ADJACENT_DIFFERENCE:
            failures.append(
                f"{action}: adjacent difference {worst:.5f} exceeds "
                f"{MAX_ADJACENT_DIFFERENCE:.2f}"
            )
    if failures:
        raise SystemExit("FOX_ANIMATION_CONTINUITY_FAIL\n" + "\n".join(failures))
    print("FOX_ANIMATION_CONTINUITY_OK")


if __name__ == "__main__":
    main()
