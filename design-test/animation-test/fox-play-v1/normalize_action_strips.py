#!/usr/bin/env python3
"""Split generated six-pose strips and normalize them to the app's 192x208 frame."""

from pathlib import Path
from collections import deque
from PIL import Image


ROOT = Path(__file__).resolve().parent
GENERATED = ROOT / "generated"
FRAMES = ROOT / "frames"
NORMALIZED = ROOT / "normalized"
CANVAS = (192, 208)
TARGET_HEIGHT = 171
TARGET_WIDTH = 182
TARGET_CENTER_X = 96
TARGET_BASELINE = 190


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


def split_strip(strip: Path, action: str) -> list[Path]:
    image = Image.open(strip).convert("RGBA")
    width, height = image.size
    alpha_values = list(image.getchannel("A").getdata())
    components = sorted(connected_components(image), key=len, reverse=True)[:6]
    if len(components) != 6:
        raise ValueError(f"{strip}: expected six pose components, found {len(components)}")
    poses = []
    for component in components:
        xs = [index % width for index in component]
        ys = [index // width for index in component]
        bbox = (min(xs), min(ys), max(xs) + 1, max(ys) + 1)
        poses.append((bbox, component))
    poses.sort(key=lambda item: item[0][0])
    source_dir = FRAMES / action
    source_dir.mkdir(parents=True, exist_ok=True)
    for old in source_dir.glob("*.png"):
        old.unlink()
    paths = []
    for index, (bbox, component) in enumerate(poses):
        path = source_dir / f"{index:02d}.png"
        left, _, right, _ = bbox
        pose = image.crop((left, 0, right, height))
        component_shifted = {
            (value // width) * pose.width + (value % width - left)
            for value in component
        }
        pose_alpha = Image.new("L", pose.size, 0)
        pose_alpha.putdata([
            alpha_values[y * width + x + left] if y * pose.width + x in component_shifted else 0
            for y in range(height)
            for x in range(pose.width)
        ])
        pose.putalpha(pose_alpha)
        pose.save(path)
        paths.append(path)
    return paths


def normalize(action: str, source_paths: list[Path]) -> list[Path]:
    frames = [Image.open(path).convert("RGBA") for path in source_paths]
    reference_bbox = frames[0].getchannel("A").getbbox()
    if reference_bbox is None:
        raise ValueError(f"{action}: empty reference frame")
    bboxes = [frame.getchannel("A").getbbox() for frame in frames]
    if any(bbox is None for bbox in bboxes):
        raise ValueError(f"{action}: empty frame")
    max_width = max(bbox[2] - bbox[0] for bbox in bboxes if bbox is not None)
    max_height = max(bbox[3] - bbox[1] for bbox in bboxes if bbox is not None)
    scale = min(TARGET_HEIGHT / max_height, TARGET_WIDTH / max_width)
    reference_bottom = reference_bbox[3]
    if action == "jump":
        minimum_top = min(bbox[1] for bbox in bboxes if bbox is not None)
        vertical_span = reference_bottom - minimum_top
        if vertical_span > 0:
            scale = min(scale, (TARGET_BASELINE - 8) / vertical_span)
    output_dir = NORMALIZED / action
    output_dir.mkdir(parents=True, exist_ok=True)
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
        if action == "jump":
            target_bottom = TARGET_BASELINE + round((bbox[3] - reference_bottom) * scale)
        else:
            target_bottom = TARGET_BASELINE
        y = target_bottom - resized.height
        canvas.alpha_composite(resized, (x, y))
        bbox = canvas.getchannel("A").getbbox()
        if bbox is None or bbox[0] <= 0 or bbox[1] <= 0 or bbox[2] >= CANVAS[0] or bbox[3] >= CANVAS[1]:
            raise ValueError(f"{action}/{index:02d}: normalized frame touches canvas edge: {bbox}")
        output = output_dir / f"{index:02d}.png"
        canvas.save(output)
        outputs.append(output)
    return outputs


def main() -> None:
    actions = {"run": GENERATED / "run-strip.png", "jump": GENERATED / "jump-strip.png", "play": GENERATED / "play-strip.png"}
    for action, strip in actions.items():
        normalize(action, split_strip(strip, action))


if __name__ == "__main__":
    main()
