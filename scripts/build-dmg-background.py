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
    """Slim drag arrow centred between the two icon positions (y=205).
    Layout is intentionally tight at the top of the icon view so it
    survives even when Finder shows toolbar AND statusbar (which can
    eat ~120 of the 400 vertical points). Must align with
    build-release.sh AppleScript icon positions: app at x=180 (right
    edge ~224), Applications at x=420 (left edge ~376)."""
    cy = 205
    x_start = 250          # safely past the right edge of the .app icon
    x_end = 350            # safely before the Applications shortcut
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


def draw_glass_pill(img: Image.Image, x0: int, y0: int, x1: int, y1: int) -> None:
    """Apple Liquid-Glass pill — drop shadow, backdrop blur of mesh, a
    milky tint, a specular top highlight, and a hairline rim. Used to
    frame the wordmark halves around the central 'Read me first.txt'."""
    w, h = x1 - x0, y1 - y0
    radius = h // 2   # full capsule

    # 1. Drop shadow
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle(
        [(x0, y0 + 6), (x1, y1 + 6)], radius=radius, fill=(20, 40, 80, 80)
    )
    sh = sh.filter(ImageFilter.GaussianBlur(radius=10))
    img.alpha_composite(sh)

    # 2. Backdrop blur of the mesh underneath
    crop = img.crop((x0, y0, x1, y1)).filter(ImageFilter.GaussianBlur(radius=14))
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [(0, 0), (w - 1, h - 1)], radius=radius, fill=255
    )
    img.paste(crop, (x0, y0), mask)

    # 3. Milky white tint
    tint = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(tint).rounded_rectangle(
        [(x0, y0), (x1, y1)], radius=radius, fill=(255, 255, 255, 70)
    )
    img.alpha_composite(tint)

    # 4. Specular top highlight — soft white fade across the upper third
    spec = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(spec)
    spec_h = (y1 - y0) // 2
    for i in range(spec_h):
        a = int(90 * (1 - i / spec_h) ** 2)
        sdraw.rectangle([(x0, y0 + i), (x1, y0 + i + 1)],
                        fill=(255, 255, 255, a))
    spec_mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(spec_mask).rounded_rectangle(
        [(x0, y0), (x1, y1)], radius=radius, fill=255
    )
    spec_clipped = Image.new("RGBA", img.size, (0, 0, 0, 0))
    spec_clipped.paste(spec, (0, 0), spec_mask)
    img.alpha_composite(spec_clipped)

    # 5. Hairlines — bright top rim + dim inner stroke for glass thickness
    edges = Image.new("RGBA", img.size, (0, 0, 0, 0))
    edraw = ImageDraw.Draw(edges)
    edraw.rounded_rectangle(
        [(x0, y0), (x1, y1)], radius=radius,
        outline=(255, 255, 255, 180), width=1,
    )
    edraw.rounded_rectangle(
        [(x0 + 1, y0 + 1), (x1 - 1, y1 - 1)], radius=radius - 1,
        outline=(40, 60, 100, 38), width=1,
    )
    img.alpha_composite(edges)


def _text_in_box(img: Image.Image, text: str, font,
                 box: tuple[int, int, int, int], fill) -> None:
    """Render text centred inside the given (x0, y0, x1, y1) rectangle."""
    draw = ImageDraw.Draw(img)
    x0, y0, x1, y1 = box
    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    # textbbox returns offsets — adjust so vertical centring looks right
    # by anchoring to the font's ascent line.
    th = bbox[3] - bbox[1]
    tx = x0 + ((x1 - x0) - tw) // 2 - bbox[0]
    ty = y0 + ((y1 - y0) - th) // 2 - bbox[1]
    draw.text((tx, ty), text, font=font, fill=fill)


def draw_content(img: Image.Image) -> None:
    """Apple Liquid-Glass wordmark — split into two glass capsules that
    frame the central 'Read me first.txt' (placed by build-release.sh at
    x=300, y=75). Plus the drag arrow between icon slots and a drag hint
    below the icon row."""
    # Glass pill geometry — symmetric, framing the centred text-file slot.
    pill_y0, pill_y1 = 22, 70
    left_box = (28, pill_y0, 218, pill_y1)
    right_box = (382, pill_y0, 572, pill_y1)
    draw_glass_pill(img, *left_box)
    draw_glass_pill(img, *right_box)

    # Wordmark halves
    wm_font = _font(22, "bold")
    _text_in_box(img, "Whisper", wm_font, left_box, fill=(22, 34, 60, 252))
    _text_in_box(img, "Caption", wm_font, right_box, fill=(22, 34, 60, 252))

    draw_arrow(img)

    # Drag hint — moved low enough to clear icon labels (~y=272) but high
    # enough to stay visible when Finder shows the bottom statusbar.
    _text_center(img, "Drag WhisperCaption  →  Applications",
                 _font(11, "regular"), y=290, fill=(40, 60, 100, 215))


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
