#!/usr/bin/env python3
"""Prepare launcher icons from assets/icon/app_icon.png with Pillow.

Run this script, then run dart run flutter_launcher_icons for Android resources.
The iOS asset catalog keeps its existing slots and filenames.
"""

import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageOps

ROOT = Path(__file__).resolve().parent.parent
ICON_DIR = ROOT / "assets/icon"
IOS_CATALOG = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
SIZE = 1024
ADAPTIVE_ART_SIZE = 840
RESAMPLE = Image.Resampling.LANCZOS


def opaque_icon(source):
    """Extend the purple backdrop into corners that the system masks."""
    backdrop = Image.new("RGB", (2, 2))
    backdrop.putdata([
        source.getpixel((200, 105))[:3],
        source.getpixel((823, 105))[:3],
        source.getpixel((200, 919))[:3],
        source.getpixel((823, 919))[:3],
    ])
    icon = backdrop.resize(source.size, Image.Resampling.BILINEAR)
    icon.paste(source, mask=source.getchannel("A"))
    return icon


def adaptive_icon(icon):
    """Keep the artwork inside Android's central circle and extend its edges."""
    art = icon.resize((ADAPTIVE_ART_SIZE, ADAPTIVE_ART_SIZE), RESAMPLE)
    padding = (SIZE - ADAPTIVE_ART_SIZE) // 2
    padded = Image.new("RGB", (SIZE, ADAPTIVE_ART_SIZE))
    padded.paste(art.crop((0, 0, 1, art.height)).resize((padding, art.height)), (0, 0))
    padded.paste(art, (padding, 0))
    padded.paste(art.crop((art.width - 1, 0, art.width, art.height)).resize(
        (padding, art.height)), (padding + art.width, 0))
    result = Image.new("RGB", (SIZE, SIZE))
    result.paste(padded.crop((0, 0, SIZE, 1)).resize((SIZE, padding)), (0, 0))
    result.paste(padded, (0, padding))
    result.paste(padded.crop((0, art.height - 1, SIZE, art.height)).resize(
        (SIZE, padding)), (0, padding + art.height))
    return result


def themed_icon(source):
    """Preserve the purple receipt ink as cutouts in the monochrome icon."""
    light_ink = source.getchannel("G").point(
        lambda value: max(0, min(255, (value - 148) * 5))
    )
    alpha = ImageChops.darker(light_ink, source.getchannel("A"))
    alpha = alpha.resize((ADAPTIVE_ART_SIZE, ADAPTIVE_ART_SIZE), RESAMPLE)
    mask = ImageOps.expand(alpha, border=(SIZE - ADAPTIVE_ART_SIZE) // 2)
    icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    icon.putalpha(mask)
    return icon


def themed_preview(icon):
    visible = SIZE * 2 // 3
    margin = (SIZE - visible) // 2
    glyph = icon.getchannel("A").crop((margin, margin, margin + visible, margin + visible))
    glyph = glyph.resize((512, 512), RESAMPLE)
    preview = Image.new("RGB", (1144, 592), "white")
    for index, (background, foreground) in enumerate([
        ("#e6ddff", "#32246b"),
        ("#32246b", "#e6ddff"),
    ]):
        tile = Image.new("RGB", glyph.size, background)
        tile.paste(foreground, (0, 0, 512, 512), glyph)
        circle = Image.new("L", tile.size)
        ImageDraw.Draw(circle).ellipse((0, 0, 511, 511), fill=255)
        preview.paste(tile, (40 + index * 552, 40), circle)
    return preview


def main():
    with Image.open(ICON_DIR / "app_icon.png") as image:
        source = image.convert("RGBA")
    if source.size != (SIZE, SIZE):
        raise ValueError("The launcher source must be 1024 x 1024 pixels.")

    opaque = opaque_icon(source)
    mono = themed_icon(source)
    source.save(ICON_DIR / "launcher_legacy.png")
    adaptive_icon(opaque).save(ICON_DIR / "adaptive_foreground.png")
    mono.save(ICON_DIR / "adaptive_monochrome.png")
    themed_preview(mono).save(ICON_DIR / "preview_themed.png")

    catalog = json.loads((IOS_CATALOG / "Contents.json").read_text(encoding="utf-8"))
    for slot in catalog["images"]:
        width, height = (float(value) for value in slot["size"].split("x"))
        scale = int(slot["scale"].removesuffix("x"))
        size = (round(width * scale), round(height * scale))
        opaque.resize(size, RESAMPLE).save(IOS_CATALOG / slot["filename"])


if __name__ == "__main__":
    main()
