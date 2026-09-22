#!/usr/bin/env python3
"""Normalize idle/working fox frames to one visual scale and baseline."""

from pathlib import Path
from PIL import Image


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "frames"
OUTPUT = ROOT / "normalized"
CANVAS = (192, 208)
TARGET_HEIGHT = 171
BASELINE = 190


def normalize(source: Path, destination: Path) -> None:
    image = Image.open(source).convert("RGBA")
    alpha = image.getchannel("A")
    bbox = alpha.getbbox()
    if bbox is None:
        raise ValueError(f"empty alpha channel: {source}")

    cropped = image.crop(bbox)
    target_width = max(1, round(cropped.width * TARGET_HEIGHT / cropped.height))
    resized = cropped.resize((target_width, TARGET_HEIGHT), Image.Resampling.LANCZOS)

    canvas = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
    x = round((CANVAS[0] - target_width) / 2)
    y = BASELINE - TARGET_HEIGHT
    canvas.alpha_composite(resized, (x, y))
    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(destination)


def main() -> None:
    if OUTPUT.exists():
        for path in OUTPUT.glob("*.png"):
            path.unlink()
    for kind in ("idle", "running"):
        for source in sorted((SOURCE / kind).glob("*.png")):
            normalize(source, OUTPUT / f"{kind}-{source.stem}.png")


if __name__ == "__main__":
    main()
