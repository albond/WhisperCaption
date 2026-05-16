#!/usr/bin/env python3
"""
Themed background image for the WhisperCaption DMG installer.

Renders a PNG at 1:1 pixel-to-point — that's how Finder lays out icon-view
backgrounds for mounted disk images. The image dimensions are therefore
equal to the DMG window's point dimensions (600×400). On Retina displays
that looks slightly soft; the alternative (a multi-resolution TIFF) would
double the build complexity without much visible win.

Design: Apple Liquid-Glass colour idiom — bright iridescent cyan / sky /
mint / coral mesh-gradient, a navy wordmark with a soft white glow for
legibility, a glass-style drag arrow between the icon slots, and a
discreet drag hint at the bottom. Window-bounds, icon positions, and the
arrow location are all in points so they line up with the AppleScript in
build-release.sh.

Usage:
    python3 scripts/build-dmg-background.py [output_path]

Default output: build/dmg-background.png

Requires: Pillow (`pip install pillow`). The release pipeline falls back
to a plain DMG without custom layout if Pillow is missing.
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:
    print("ERROR: Pillow is not installed. Install with: pip install pillow",
          file=sys.stderr)
    sys.exit(1)


# Canvas — exact point size of the DMG window (600×400). Must match the
# `set the bounds` line in build-release.sh.
W, H = 600, 400


# ─── Font loading ──────────────────────────────────────────────────────────

def _font(size: int, weight: str = "regular") -> ImageFont.FreeTypeFont:
    candidates = {
        "regular": (
            "/System/Library/Fonts/SFNS.ttf",
            "/System/Library/Fonts/Helvetica.ttc",
            "/System/Library/Fonts/HelveticaNeue.ttc",
            "/System/Library/Fonts/Supplemental/Arial.ttf",
        ),
        "bold": (
            "/System/Library/Fonts/SFNS.ttf",
            "/System/Library/Fonts/Helvetica.ttc",
            "/System/Library/Fonts/HelveticaNeue.ttc",
            "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        ),
    }
    for path in candidates.get(weight, candidates["regular"]):
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                continue
    return ImageFont.load_default()


# ─── Bright Liquid-Glass mesh gradient ─────────────────────────────────────

def draw_mesh_gradient(img: Image.Image) -> None:
    """Bright iridescent mesh — saturated cyan, sky-blue, mint, coral.
    Wide overlapping blobs so each colour reaches the centre instead of
    fading into grey."""
    ImageDraw.Draw(img).rectangle([(0, 0), (W, H)], fill=(248, 250, 252, 255))

    blobs = (
        (0.00, 0.05, 360, ( 80, 200, 236, 255)),   # vivid cyan, top-left
        (1.00, 0.05, 350, (140, 198, 250, 255)),   # sky blue, top-right
        (0.05, 1.00, 350, (164, 230, 196, 255)),   # mint, bottom-left
        (1.00, 1.00, 350, (250, 168, 148, 255)),   # warm coral, bottom-right
    )

    for fx, fy, r, rgba in blobs:
        cx, cy = int(W * fx), int(H * fy)
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(layer).ellipse(
            [(cx - r, cy - r), (cx + r, cy + r)], fill=rgba
        )
        layer = layer.filter(ImageFilter.GaussianBlur(radius=75))
        img.alpha_composite(layer)


def draw_vignette(img: Image.Image) -> None:
    """Very subtle darkened edges to anchor the corners on the light bg."""
    vig = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    vdraw = ImageDraw.Draw(vig)
    for inset in range(0, 70, 4):
        alpha = int(18 * (1 - inset / 70))
        if alpha <= 0:
            break
        vdraw.rounded_rectangle(
            [(inset, inset), (W - inset, H - inset)],
            radius=20 + inset // 4,
            outline=(28, 60, 100, alpha),
            width=4,
        )
    vig = vig.filter(ImageFilter.GaussianBlur(radius=7))
    img.alpha_composite(vig)


# ─── Glass arrow between icon slots ────────────────────────────────────────

def draw_arrow(img: Image.Image) -> None:
    """Slim drag arrow centred between the two icon positions (y=235)."""
    cy = 235
    x_start = 240          # safely past the right edge of the .app icon
    x_end = 360            # safely before the Applications shortcut
    head = 14

    # Drop shadow
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(sh)
    sd.rounded_rectangle(
        [(x_start, cy - 3 + 4), (x_end - head, cy + 3 + 4)],
        radius=3, fill=(20, 40, 80, 110),
    )
    sd.polygon(
        [(x_end - head - 2, cy - head + 4),
         (x_end + 2, cy + 4),
         (x_end - head - 2, cy + head + 4)],
        fill=(20, 40, 80, 110),
    )
    sh = sh.filter(ImageFilter.GaussianBlur(radius=6))
    img.alpha_composite(sh)

    # Tail
    body = Image.new("RGBA", img.size, (0, 0, 0, 0))
    bdraw = ImageDraw.Draw(body)
    bdraw.rounded_rectangle(
        [(x_start, cy - 3), (x_end - head, cy + 3)],
        radius=3, fill=(255, 255, 255, 232),
    )
    # Head
    bdraw.polygon(
        [(x_end - head - 3, cy - head),
         (x_end, cy),
         (x_end - head - 3, cy + head)],
        fill=(255, 255, 255, 234),
    )
    img.alpha_composite(body)

    # Subtle inner stroke for definition
    edge = Image.new("RGBA", img.size, (0, 0, 0, 0))
    edraw = ImageDraw.Draw(edge)
    edraw.rounded_rectangle(
        [(x_start, cy - 3), (x_end - head, cy + 3)],
        radius=3, outline=(28, 60, 100, 80), width=1,
    )
    edraw.polygon(
        [(x_end - head - 3, cy - head),
         (x_end, cy),
         (x_end - head - 3, cy + head)],
        outline=(28, 60, 100, 80),
    )
    img.alpha_composite(edge)


# ─── Wordmark + drag hint ──────────────────────────────────────────────────

def _text_center(img: Image.Image, text: str, font, y: int, fill):
    draw = ImageDraw.Draw(img)
    bbox = draw.textbbox((0, 0), text, font=font)
    w = bbox[2] - bbox[0]
    draw.text(((W - w) // 2, y), text, font=font, fill=fill)


def draw_content(img: Image.Image) -> None:
    """Wordmark up top with a soft glow underneath, then the drag arrow
    (drawn separately), then a quiet drag hint at the bottom."""
    wm_font = _font(30, "bold")

    # Soft white glow under the wordmark
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(sh)
    bbox = sd.textbbox((0, 0), "WhisperCaption", font=wm_font)
    wm_w = bbox[2] - bbox[0]
    sx, sy = (W - wm_w) // 2, 48
    sd.text((sx, sy + 2), "WhisperCaption", font=wm_font,
            fill=(255, 255, 255, 220))
    sh = sh.filter(ImageFilter.GaussianBlur(radius=7))
    img.alpha_composite(sh)

    # Wordmark itself
    _text_center(img, "WhisperCaption", wm_font,
                 y=48, fill=(22, 34, 60, 252))

    draw_arrow(img)

    # Drag hint
    _text_center(img, "Drag WhisperCaption  →  Applications",
                 _font(11, "regular"), y=370, fill=(40, 60, 100, 215))


# ─── Composition ───────────────────────────────────────────────────────────

def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("build/dmg-background.png")
    out.parent.mkdir(parents=True, exist_ok=True)

    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw_mesh_gradient(img)
    draw_vignette(img)
    draw_content(img)

    img.save(out, "PNG", optimize=True)
    print(f"Wrote {out}  ({W}×{H}, 1×)")


if __name__ == "__main__":
    main()
