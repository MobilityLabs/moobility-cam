#!/usr/bin/env python3
"""Build the default backgrounds and the idle image from one office scene.

raw/cows/office.png has flat magenta window panes. Each season's view from raw/seasons/ shows through
them, so the room is identical in all four images. Output is committed, so a build doesn't need Python.

Usage: uv run --with Pillow --with numpy python scripts/compose-defaults.py
"""
import pathlib

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[1]
SEASONS = ("spring", "summer", "autumn", "winter")
OUTPUT = (1920, 1080)
WINDOW_BOTTOM = 0.42  # the window ends above this fraction of the image's height
HORIZON = 0.45  # how far down each view the visible band of it is centered
IDLE_BRIGHTNESS = 0.45
IDLE_PANES = (10, 16, 38)
IDLE_TEXT = "Moobility Cam isn't running"
TEXT_SCALE = 4  # a small bitmap font scaled up with hard edges, to match the pixel art


def office_and_mask() -> tuple[Image.Image, Image.Image]:
    office = Image.open(ROOT / "raw/cows/office.png").convert("RGB")
    a = np.asarray(office).astype(int)
    panes = (a[..., 0] > 170) & (a[..., 1] < 110) & (a[..., 2] > 170)
    panes[round(a.shape[0] * WINDOW_BOTTOM):] = False  # the monitors have pink bars of code
    mask = Image.fromarray((panes * 255).astype(np.uint8)).resize(OUTPUT, Image.LANCZOS)
    # Grow slightly so no magenta fringe survives the upscale.
    mask = mask.filter(ImageFilter.MaxFilter(5))
    return office.resize(OUTPUT, Image.LANCZOS), mask


def window_box(mask: Image.Image) -> tuple[int, int, int, int]:
    box = mask.getbbox()
    assert box, "no window panes found in the office image"
    return box


def view_for(season: str, box: tuple[int, int, int, int]) -> Image.Image:
    """The season's view, covering the window area, on a full-size canvas."""
    view = Image.open(ROOT / f"raw/seasons/{season}.png").convert("RGB")
    w, h = box[2] - box[0], box[3] - box[1]
    scale = max(w / view.width, h / view.height)
    scaled = view.resize((round(view.width * scale), round(view.height * scale)), Image.LANCZOS)
    left = (scaled.width - w) // 2
    top = min(max(round(scaled.height * HORIZON) - h // 2, 0), scaled.height - h)
    canvas = Image.new("RGB", OUTPUT)
    canvas.paste(scaled.crop((left, top, left + w, top + h)), box[:2])
    return canvas


def idle(office: Image.Image, mask: Image.Image, box: tuple[int, int, int, int]) -> Image.Image:
    dim = office.point(lambda v: round(v * IDLE_BRIGHTNESS))
    dim.paste(Image.new("RGB", OUTPUT, IDLE_PANES), mask=mask)
    font = ImageFont.load_default(size=11)
    left, top, right, bottom = font.getbbox(IDLE_TEXT)
    line = Image.new("L", (right - left + 2, bottom - top + 2), 0)
    ImageDraw.Draw(line).text((-left + 1, -top + 1), IDLE_TEXT, fill=255, font=font)
    line = line.point(lambda v: 255 if v > 110 else 0)
    line = line.resize((line.width * TEXT_SCALE, line.height * TEXT_SCALE), Image.NEAREST)
    x = (box[0] + box[2] - line.width) // 2
    y = (box[1] + box[3] - line.height) // 2
    dim.paste(Image.new("RGB", line.size, (235, 238, 245)), (x, y), line)
    return dim


def main() -> None:
    office, mask = office_and_mask()
    box = window_box(mask)
    for season in SEASONS:
        image = office.copy()
        image.paste(view_for(season, box), mask=mask)
        image.save(ROOT / f"App/Seasons/{season}.jpg", quality=90, optimize=True)
    idle(office, mask, box).save(ROOT / "Extension/idle.png", optimize=True)


if __name__ == "__main__":
    main()
