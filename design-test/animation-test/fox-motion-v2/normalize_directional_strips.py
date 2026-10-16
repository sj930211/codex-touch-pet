#!/usr/bin/env python3
"""Split the approved 8-pose directional strips into stable Touch Bar frames."""

from collections import deque
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parent
GENERATED = ROOT / "generated"
NORMALIZED = ROOT / "normalized"
CANVAS = (192, 208)
TARGET_HEIGHT = 171
TARGET_WIDTH = 182
TARGET_CENTER_X = 96
TARGET_BASELINE = 190
FRAME_COUNT = 8


def connected_components(image: Image.Image) -> list[set[int]]:
    alpha = image.getchannel("A")
    width, height = image.size
    values = list(alpha.getdata())
    active = {index for index, value in enumerate(values) if value > 8}
    components: list[set[int]] = []
    while active:
        start = active.pop()
        component = {start}
        queue = deque([start])
        while queue:
            index = queue.popleft()
            x, y = index % width, index // width
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    nx, ny = x + dx, y + dy
                    if not (0 <= nx < width and 0 <= ny < height):
                        continue
                    neighbor = ny * width + nx
                    if neighbor in active:
                        active.remove(neighbor)
                        component.add(neighbor)
                        queue.append(neighbor)
        components.append(component)
    return components


def split_strip(strip: Path, direction: str) -> list[Path]:
    image = Image.open(strip).convert("RGBA")
    width, height = image.size
    alpha_values = list(image.getchannel("A").getdata())
    components = sorted(connected_components(image), key=len, reverse=True)
    components = [component for component in components if len(component) > 80][:FRAME_COUNT]
    if len(components) != FRAME_COUNT:
        raise ValueError(f"{strip}: expected {FRAME_COUNT} pose components, found {len(components)}")

    poses = []
    for component in components:
        xs = [index % width for index in component]
        ys = [index // width for index in component]
        bbox = (min(xs), min(ys), max(xs) + 1, max(ys) + 1)
        poses.append((bbox, component))
    poses.sort(key=lambda item: item[0][0])

    source_dir = ROOT / "frames" / direction
    source_dir.mkdir(parents=True, exist_ok=True)
    for old in source_dir.glob("*.png"):
        old.unlink()

    paths = []
    for index, (bbox, component) in enumerate(poses):
        left, top, right, bottom = bbox
        pose = image.crop((left, top, right, bottom))
        pose_alpha = Image.new("L", pose.size, 0)
        pose_alpha.putdata([
            alpha_values[(top + y) * width + (left + x)]
            if (top + y) * width + (left + x) in component
            else 0
            for y in range(pose.height)
            for x in range(pose.width)
        ])
        pose.putalpha(pose_alpha)
        path = source_dir / f"{index:02d}.png"
        pose.save(path)
        paths.append(path)
    return paths


def normalize(direction: str, source_paths: list[Path]) -> list[Path]:
    frames = [Image.open(path).convert("RGBA") for path in source_paths]
    bboxes = [frame.getchannel("A").getbbox() for frame in frames]
    if any(bbox is None for bbox in bboxes):
        raise ValueError(f"{direction}: empty frame")
    max_width = max(bbox[2] - bbox[0] for bbox in bboxes if bbox is not None)
    max_height = max(bbox[3] - bbox[1] for bbox in bboxes if bbox is not None)
    scale = min(TARGET_HEIGHT / max_height, TARGET_WIDTH / max_width)

    output_dir = NORMALIZED / direction
    output_dir.mkdir(parents=True, exist_ok=True)
    for old in output_dir.glob("*.png"):
        old.unlink()

    outputs = []
    for index, frame in enumerate(frames):
        bbox = frame.getchannel("A").getbbox()
        assert bbox is not None
        cropped = frame.crop(bbox)
        resized = cropped.resize(
            (round(cropped.width * scale), round(cropped.height * scale)),
            Image.Resampling.LANCZOS,
        )
        canvas = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
        x = round(TARGET_CENTER_X - resized.width / 2)
        y = TARGET_BASELINE - resized.height
        canvas.alpha_composite(resized, (x, y))
        output = output_dir / f"{index:02d}.png"
        canvas.save(output)
        outputs.append(output)
    return outputs


def main() -> None:
    for direction in ("run-left", "run-right"):
        strip = GENERATED / f"fox-{direction}-strip.png"
        normalize(direction, split_strip(strip, direction))


if __name__ == "__main__":
    main()
