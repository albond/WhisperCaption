#!/usr/bin/env python3
"""
Placeholder AppIcon generator for WhisperCaption.

Design: holographic-glass "CC" — concentric arc rings (broadcast-wave motif)
behind a bright white-cyan CC glyph with chromatic edge offset and a soft
cyan halo. Background is a vertical 3-stop gradient (cyan → indigo → void)
with a blurred top-left highlight that suggests a light source.

This is a placeholder; replace before public release with a real icon.

Usage:
    python3 scripts/generate_appicon.py

Writes PNGs into WhisperCaption/Assets.xcassets/AppIcon.appiconset/ and
rewrites Contents.json with explicit filenames.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO_ROOT = Path(__file__).resolve().parent.parent
APPICONSET = REPO_ROOT / "WhisperCaption" / "Assets.xcassets" / "AppIcon.appiconset"

SLOTS = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

# Palette
BG_TOP = (12, 32, 70)            # deep cyan-blue
BG_MID = (38, 16, 80)            # indigo
BG_BOT = (8, 6, 28)              # near-black void
ACCENT_GLOW = (90, 220, 255)     # cyan glow
ACCENT_HOT = (255, 90, 200)      # magenta — chromatic offset
HIGHLIGHT_TINT = (130, 200, 255) # top-left spotlight
FG = (242, 250, 255)             # soft white

CORNER_RADIUS_RATIO = 0.225
GLYPH_WIDTH_RATIO = 0.60


def _three_stop_gradient(size: int) -> Image.Image:
    img = Image.new("RGB", (size, size))
    px = img.load()
    half = max(size - 1, 1) / 2.0
    for y in range(size):
        t = y / max(size - 1, 1)
        if t < 0.5:
            local = t * 2
            r = BG_TOP[0] + (BG_MID[0] - BG_TOP[0]) * local
            g = BG_TOP[1] + (BG_MID[1] - BG_TOP[1]) * local
            b = BG_TOP[2] + (BG_MID[2] - BG_TOP[2]) * local
        else:
            local = (t - 0.5) * 2
            r = BG_MID[0] + (BG_BOT[0] - BG_MID[0]) * local
            g = BG_MID[1] + (BG_BOT[1] - BG_MID[1]) * local
            b = BG_MID[2] + (BG_BOT[2] - BG_MID[2]) * local
        row = (int(r), int(g), int(b))
        for x in range(size):
            px[x, y] = row
    return img


def _rounded_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    radius = int(size * CORNER_RADIUS_RATIO)
    draw.rounded_rectangle((0, 0, size, size), radius=radius, fill=255)
    return mask


def _add_top_left_highlight(img: Image.Image, size: int) -> Image.Image:
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    r = size * 0.55
    cx, cy = size * 0.28, size * 0.22
    draw.ellipse((cx - r, cy - r, cx + r, cy + r),
                 fill=(*HIGHLIGHT_TINT, 90))
    layer = layer.filter(ImageFilter.GaussianBlur(radius=size * 0.18))
    return Image.alpha_composite(img.convert("RGBA"), layer)


def _draw_arc_rings(img: Image.Image, size: int) -> Image.Image:
    # Sound-wave arcs emanating from upper-right corner.
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cx, cy = size * 1.0, 0.0
    base_r = size * 0.52
    width = max(2, int(size * 0.008))
    for i, mult in enumerate((1.0, 1.35, 1.75, 2.20)):
        radius = base_r * mult
        alpha = max(28, 110 - i * 22)
        bbox = (cx - radius, cy - radius, cx + radius, cy + radius)
        draw.arc(bbox, start=140, end=230, fill=(*ACCENT_GLOW, alpha), width=width)
    layer = layer.filter(ImageFilter.GaussianBlur(radius=max(0.5, size * 0.0035)))
    return Image.alpha_composite(img, layer)


def _load_bold_font(target_height: int) -> ImageFont.FreeTypeFont:
    candidates = [
        "/System/Library/Fonts/SFCompact.ttf",
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/SFNSDisplay.ttf",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/Library/Fonts/Arial Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, target_height)
            except OSError:
                continue
    return ImageFont.load_default()


def _measure_glyph(text: str, target_w: int):
    draw_dummy = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    font_size = int(target_w * 1.4)
    while font_size > 6:
        font = _load_bold_font(font_size)
        bbox = draw_dummy.textbbox((0, 0), text, font=font, stroke_width=0)
        width = bbox[2] - bbox[0]
        if width <= target_w:
            return font, bbox
        font_size -= 1
    return _load_bold_font(6), draw_dummy.textbbox((0, 0), text, font=_load_bold_font(6))


def _draw_glyph_with_effects(img: Image.Image, size: int) -> Image.Image:
    text = "CC"
    target_w = int(size * GLYPH_WIDTH_RATIO)
    font, bbox = _measure_glyph(text, target_w)
    w = bbox[2] - bbox[0]
    h = bbox[3] - bbox[1]
    x = (size - w) / 2 - bbox[0]
    y = (size - h) / 2 - bbox[1] - size * 0.02

    # Soft cyan halo behind glyph
    halo = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(halo).text((x, y), text, fill=(*ACCENT_GLOW, 220), font=font)
    halo = halo.filter(ImageFilter.GaussianBlur(radius=size * 0.045))
    img = Image.alpha_composite(img, halo)

    # Chromatic offset — only at sizes where 1px offset reads cleanly.
    if size >= 64:
        offset = max(1, int(round(size * 0.0075)))
        chrom = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        cd = ImageDraw.Draw(chrom)
        cd.text((x - offset, y), text, fill=(*ACCENT_HOT, 130), font=font)
        cd.text((x + offset, y), text, fill=(*ACCENT_GLOW, 130), font=font)
        img = Image.alpha_composite(img, chrom)

    # Main glyph
    main = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(main).text((x, y), text, fill=(*FG, 255), font=font)
    img = Image.alpha_composite(img, main)
    return img


def _render_tile(size: int) -> Image.Image:
    base = _three_stop_gradient(size).convert("RGBA")
    base = _add_top_left_highlight(base, size)
    if size >= 64:
        base = _draw_arc_rings(base, size)
    base = _draw_glyph_with_effects(base, size)

    mask = _rounded_mask(size)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(base, mask=mask)
    return out


def _filename(point: int, scale: int) -> str:
    suffix = f"@{scale}x" if scale > 1 else ""
    return f"icon_{point}x{point}{suffix}.png"


def main() -> None:
    APPICONSET.mkdir(parents=True, exist_ok=True)

    contents = {"images": [], "info": {"author": "xcode", "version": 1}}

    for point, scale in SLOTS:
        pixels = point * scale
        tile = _render_tile(pixels)
        name = _filename(point, scale)
        tile.save(APPICONSET / name, "PNG")
        contents["images"].append(
            {
                "filename": name,
                "idiom": "mac",
                "scale": f"{scale}x",
                "size": f"{point}x{point}",
            }
        )

    (APPICONSET / "Contents.json").write_text(
        json.dumps(contents, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Wrote {len(SLOTS)} icon files to {APPICONSET}")


if __name__ == "__main__":
    main()
