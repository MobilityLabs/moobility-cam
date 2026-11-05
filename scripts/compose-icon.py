#!/usr/bin/env python3
"""Build App/Assets.xcassets/AppIcon.appiconset from raw/cows/icon.png, on Apple's macOS icon grid.

Usage: uv run --with Pillow python scripts/compose-icon.py [source.png] [output.appiconset]
"""
import json
import pathlib
import sys

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANVAS = 1024
BODY = 824     # the icon's body on the 1024 grid; the margin stays transparent
RADIUS = 185
INSET = 40     # trims the generated art's own rounded corners, on the source's scale
SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def master(source: pathlib.Path) -> Image.Image:
    art = Image.open(source).convert("RGBA")
    art = art.crop((INSET, INSET, art.width - INSET, art.height - INSET)).resize((BODY, BODY), Image.LANCZOS)
    mask = Image.new("L", (BODY * 4, BODY * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, BODY * 4 - 1, BODY * 4 - 1), RADIUS * 4, fill=255)
    art.putalpha(mask.resize((BODY, BODY), Image.LANCZOS))
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(art, ((CANVAS - BODY) // 2, (CANVAS - BODY) // 2), art)
    return canvas


def main() -> None:
    source = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "raw/cows/icon.png"
    output = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "App/Assets.xcassets/AppIcon.appiconset"
    output.mkdir(parents=True, exist_ok=True)
    big = master(source)
    images = []
    for size, scale in SIZES:
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        big.resize((size * scale, size * scale), Image.LANCZOS).save(output / name, optimize=True)
        images.append({"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x", "filename": name})
    (output / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (output.parent / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


if __name__ == "__main__":
    main()
