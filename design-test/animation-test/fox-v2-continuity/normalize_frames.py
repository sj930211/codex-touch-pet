#!/usr/bin/env python3
"""Apply one shared transform per row so motion remains spatially coherent."""

from pathlib import Path
from PIL import Image


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "frames"
OUTPUT = ROOT / "normalized"
CANVAS = (192, 208)
TARGET_HEIGHT = 171
TARGET_WIDTH = 182
TARGET_CENTER_X = 96
TARGET_BASELINE = 190


def normalize_state(state_dir: Path) -> None:
    frames = [Image.open(path).convert("RGBA") for path in sorted(state_dir.glob("*.png"))]
    if len(frames) != 6:
        raise ValueError(f"{state_dir.name}: expected 6 frames, found {len(frames)}")
    reference_bbox = frames[0].getchannel("A").getbbox()
    if reference_bbox is None:
        raise ValueError(f"{state_dir.name}: empty reference frame")

    reference_width = reference_bbox[2] - reference_bbox[0]
    reference_height = reference_bbox[3] - reference_bbox[1]
    scale = min(TARGET_HEIGHT / reference_height, TARGET_WIDTH / reference_width)
    resized_canvas = (round(CANVAS[0] * scale), round(CANVAS[1] * scale))
    reference_center_x = (reference_bbox[0] + reference_bbox[2]) * scale / 2
    reference_bottom = reference_bbox[3] * scale
    offset = (
        round(TARGET_CENTER_X - reference_center_x),
        round(TARGET_BASELINE - reference_bottom),
    )

    output_dir = OUTPUT / state_dir.name
    output_dir.mkdir(parents=True, exist_ok=True)
    for old in output_dir.glob("*.png"):
        old.unlink()
    for index, frame in enumerate(frames):
        resized = frame.resize(resized_canvas, Image.Resampling.LANCZOS)
        canvas = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
        canvas.alpha_composite(resized, offset)
        bbox = canvas.getchannel("A").getbbox()
        if bbox is None or bbox[0] <= 0 or bbox[1] <= 0 or bbox[2] >= CANVAS[0] or bbox[3] >= CANVAS[1]:
            raise ValueError(f"{state_dir.name}/{index:02d}: normalized frame touches canvas edge: {bbox}")
        canvas.save(output_dir / f"{index:02d}.png")


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for state_dir in sorted(path for path in SOURCE.iterdir() if path.is_dir()):
        normalize_state(state_dir)


if __name__ == "__main__":
    main()
