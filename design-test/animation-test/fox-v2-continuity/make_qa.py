#!/usr/bin/env python3
"""Build app-sized previews and continuity metrics for six-frame fox rows."""

import argparse
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageStat


def alpha_metrics(frame: Image.Image) -> tuple[list[int], tuple[float, float]]:
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        return [0, 0, 0, 0], (0.0, 0.0)
    alpha = frame.getchannel("A")
    total = sum(ImageStat.Stat(alpha).sum)
    if total == 0:
        return list(bbox), (0.0, 0.0)
    width, height = frame.size
    x_mask = Image.new("L", (width, height))
    y_mask = Image.new("L", (width, height))
    x_mask.putdata([x for _y in range(height) for x in range(width)])
    y_mask.putdata([y for y in range(height) for _x in range(width)])
    weighted_x = ImageStat.Stat(ImageChops.multiply(alpha, x_mask)).sum[0]
    weighted_y = ImageStat.Stat(ImageChops.multiply(alpha, y_mask)).sum[0]
    return list(bbox), (weighted_x / total * 255, weighted_y / total * 255)


def pair_difference(a: Image.Image, b: Image.Image) -> float:
    background = Image.new("RGBA", a.size, (8, 10, 14, 255))
    first = Image.alpha_composite(background, a).convert("RGB")
    second = Image.alpha_composite(background, b).convert("RGB")
    stat = ImageStat.Stat(ImageChops.difference(first, second))
    return round(sum(stat.mean) / (3 * 255), 5)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--states", nargs="+", required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    rows = []
    report = {"states": {}}
    for state in args.states:
        frames = [Image.open(path).convert("RGBA") for path in sorted((args.frames_root / state).glob("*.png"))]
        if len(frames) != 6:
            raise ValueError(f"{state}: expected 6 frames, found {len(frames)}")

        pairs = list(zip(frames, frames[1:] + frames[:1]))
        metrics = [alpha_metrics(frame) for frame in frames]
        report["states"][state] = {
            "frame_count": 6,
            "bboxes": [item[0] for item in metrics],
            "alpha_centroids": [[round(v, 2) for v in item[1]] for item in metrics],
            "adjacent_difference": [pair_difference(a, b) for a, b in pairs],
        }

        previews = []
        for frame in frames:
            width = round(frame.width * 30 / frame.height)
            thumb = frame.resize((width, 30), Image.Resampling.LANCZOS)
            canvas = Image.new("RGBA", (width, 30), (8, 10, 14, 255))
            canvas.alpha_composite(thumb)
            previews.append(canvas)
        previews[0].save(
            args.output_dir / f"{state}.gif",
            save_all=True,
            append_images=previews[1:],
            duration=[140] * 6,
            loop=0,
            disposal=2,
        )

        row = Image.new("RGBA", (6 * 192, 236), (14, 17, 24, 255))
        draw = ImageDraw.Draw(row)
        draw.text((8, 6), state, fill=(232, 236, 244, 255))
        for index, frame in enumerate(frames):
            background = Image.new("RGBA", frame.size, (20, 25, 35, 255))
            background.alpha_composite(frame)
            row.alpha_composite(background, (index * 192, 28))
        rows.append(row)

    sheet = Image.new("RGBA", (6 * 192, len(rows) * 236), (14, 17, 24, 255))
    for index, row in enumerate(rows):
        sheet.alpha_composite(row, (0, index * 236))
    sheet.save(args.output_dir / "contact-sheet.png")
    (args.output_dir / "continuity.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
