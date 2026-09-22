from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).parent
QA = ROOT / "qa"
QA.mkdir(parents=True, exist_ok=True)
DURATIONS = {
    "idle": [280, 110, 110, 140, 140, 320],
    "running": [120, 120, 120, 120, 120, 220],
}

for state, durations in DURATIONS.items():
    normalized = [ROOT / "normalized" / f"{state}-{i:02d}.png" for i in range(6)]
    source_frames = normalized if all(path.exists() for path in normalized) else [
        ROOT / "frames" / state / f"{i:02d}.png" for i in range(6)
    ]
    frames = [Image.open(path).convert("RGBA") for path in source_frames]
    enlarged = []
    for frame in frames:
        background = Image.new("RGBA", frame.size, (20, 25, 35, 255))
        background.alpha_composite(frame)
        enlarged.append(background.resize((384, 416), Image.Resampling.NEAREST))
    frame_sheet = Image.new("RGBA", (6 * 384, 446), (14, 17, 24, 255))
    frame_draw = ImageDraw.Draw(frame_sheet)
    for index, frame in enumerate(enlarged):
        frame_sheet.alpha_composite(frame, (index * 384, 30))
        frame_draw.text((index * 384 + 8, 8), str(index + 1), fill=(230, 235, 245, 255))
    frame_sheet.save(QA / f"{state}-frames-sheet.png")
    enlarged[0].save(
        QA / f"{state}-preview.gif",
        save_all=True,
        append_images=enlarged[1:],
        duration=durations,
        loop=0,
        disposal=2,
    )

    thumbs = []
    for frame in frames:
        height = 30
        width = round(frame.width * height / frame.height)
        thumb = frame.resize((width, height), Image.Resampling.LANCZOS)
        cell = Image.new("RGBA", (thumb.width + 12, height + 10), (8, 10, 14, 255))
        cell.alpha_composite(thumb, (6, 5))
        thumbs.append(cell)
    strip = Image.new("RGBA", (sum(item.width for item in thumbs), 40), (8, 10, 14, 255))
    x = 0
    for thumb in thumbs:
        strip.alpha_composite(thumb, (x, 0))
        x += thumb.width
    strip.save(QA / f"{state}-touchbar-strip.png")

    actual = []
    for frame in frames:
        width = round(frame.width * 30 / frame.height)
        thumb = frame.resize((width, 30), Image.Resampling.LANCZOS)
        background = Image.new("RGBA", thumb.size, (8, 10, 14, 255))
        background.alpha_composite(thumb)
        actual.append(background)
    actual[0].save(
        QA / f"{state}-touchbar-preview.gif",
        save_all=True,
        append_images=actual[1:],
        duration=durations,
        loop=0,
        disposal=2,
    )

sheet = Image.new("RGBA", (6 * 384, 2 * (416 + 55)), (14, 17, 24, 255))
draw = ImageDraw.Draw(sheet)
for row, state in enumerate(("idle", "running")):
    y = row * (416 + 55)
    draw.text((8, y + 2), state, fill=(230, 235, 245, 255))
    sheet.alpha_composite(Image.open(QA / f"{state}-preview.gif").convert("RGBA"), (0, y + 20))
    sheet.alpha_composite(Image.open(QA / f"{state}-touchbar-strip.png").convert("RGBA"), (6, y + 436))
sheet.save(QA / "fox-animation-test-sheet.png")
