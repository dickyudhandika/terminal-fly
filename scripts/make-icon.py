#!/usr/bin/env python3
"""Generate Terminal Fly's app icon.

Committed as a script (rather than a binary .icns only) so the icon is
reproducible and reviewable in a PR. Requires Pillow, which ships with
Hermes's Python; if it is missing, run `pip3 install pillow`.

Design: a rounded-square macOS icon holding a terminal prompt — a chevron and
underscore — over a dark teal panel, with a subtly lighter "floating" plate
behind it to hint at the always-on-top behaviour. Drawn at 3x and downsampled
for antialiasing.

Output: Resources/Assets.xcassets/AppIcon.appiconset/*.png + AppIcon.icns
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover - environment guidance
    sys.exit("Pillow is required: pip3 install pillow")

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
ICONSET = ROOT / "build" / "AppIcon.iconset"
ICNS = ROOT / "Resources" / "AppIcon.icns"

# macOS icon grid: 1024pt canvas, content inset so the rounded square matches
# the system's optical size (Big Sur+ icons sit in a 824px square within 1024).
CANVAS = 1024
INSET = 100
SUPERSAMPLE = 3

BG_TOP = (32, 44, 54)
BG_BOTTOM = (18, 26, 33)
PLATE = (44, 62, 74)
MINT = (78, 205, 196)
DIM_MINT = (56, 150, 145)
SHADOW = (8, 12, 16)

# macOS icon corner radius is ~22.37% of the content square.
CONTENT = CANVAS - 2 * INSET
RADIUS = int(CONTENT * 0.2237)


def vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    grad = Image.new("RGB", (1, size))
    px = grad.load()
    for y in range(size):
        t = y / max(size - 1, 1)
        px[0, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return grad.resize((size, size))


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size * SUPERSAMPLE, size * SUPERSAMPLE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size * SUPERSAMPLE - 1, size * SUPERSAMPLE - 1),
        radius=radius * SUPERSAMPLE,
        fill=255,
    )
    return mask.resize((size, size), Image.LANCZOS)


def draw_chevron(draw: ImageDraw.ImageDraw, origin: tuple, scale: float, color):
    """The `>` prompt marker, drawn as two thick strokes."""
    ox, oy = origin
    w = max(int(9 * scale), 1)
    joint = (ox + int(52 * scale), oy + int(46 * scale))
    draw.line([(ox, oy), joint], fill=color, width=w, joint="curve")
    draw.line([joint, (ox, oy + int(92 * scale))], fill=color, width=w, joint="curve")


def build_icon(size: int) -> Image.Image:
    s = size / CANVAS
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    content = int(CONTENT * s)
    inset = int(INSET * s)
    mask = rounded_mask(content, int(RADIUS * s))

    panel = vertical_gradient(content, BG_TOP, BG_BOTTOM).convert("RGBA")
    panel.putalpha(mask)

    # Soft drop shadow so the icon reads on light and dark desktops.
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    smask = rounded_mask(content, int(RADIUS * s))
    shadow.paste(Image.new("RGBA", (content, content), (*SHADOW, 90)),
                 (inset, inset + max(int(6 * s), 1)), smask)
    img.alpha_composite(shadow)

    # Floating "plate" peeking out behind the panel — hints at always-on-top.
    plate = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pw, ph = int(content * 0.86), int(content * 0.86)
    pmask = rounded_mask(pw, int(RADIUS * s * 0.86))
    plate.paste(Image.new("RGBA", (pw, ph), (*PLATE, 255)),
                (inset + int(content * 0.10), inset - int(content * 0.07)), pmask)
    img.alpha_composite(plate)

    img.paste(panel, (inset, inset), mask)

    draw = ImageDraw.Draw(img)

    # Title-bar strip with three dots.
    bar_h = int(content * 0.14)
    bar = Image.new("RGBA", (content, bar_h), (255, 255, 255, 18))
    bar.putalpha(Image.composite(
        Image.new("L", (content, bar_h), 18),
        Image.new("L", (content, bar_h), 0),
        rounded_mask(content, int(RADIUS * s)).crop((0, 0, content, bar_h)),
    ))
    img.alpha_composite(bar, (inset, inset))
    dot_r = max(int(6 * s), 1)
    for i in range(3):
        cx = inset + int((0.09 + i * 0.075) * content)
        cy = inset + bar_h // 2
        draw.ellipse((cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r),
                     fill=(*DIM_MINT, 220))

    # Prompt: `> _`
    prompt_scale = s * 1.25
    glyph_x = inset + int(content * 0.20)
    glyph_y = inset + int(content * 0.40)
    draw_chevron(draw, (glyph_x, glyph_y), prompt_scale, (*MINT, 255))

    ux = glyph_x + int(86 * prompt_scale / 1.25)
    uy = glyph_y + int(96 * prompt_scale / 1.25)
    uw = int(58 * prompt_scale / 1.25)
    uh = max(int(11 * s), 1)
    draw.rounded_rectangle((ux, uy - uh, ux + uw, uy), radius=uh // 2,
                           fill=(*MINT, 255))

    return img


def main() -> int:
    ASSETS.mkdir(parents=True, exist_ok=True)
    if ICONSET.exists():
        shutil.rmtree(ICONSET)
    ICONSET.mkdir(parents=True)

    # (point size, scale) pairs macOS expects inside an .iconset.
    variants = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
        (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
    ]

    # Render each distinct pixel size once, then reuse.
    cache: dict[int, Image.Image] = {}
    for points, scale in variants:
        px = points * scale
        if px not in cache:
            cache[px] = build_icon(px)
        suffix = f"{points}x{points}" + ("@2x" if scale == 2 else "")
        png = cache[px]
        png.save(ICONSET / f"icon_{suffix}.png")
        # The appiconset wants a matching PNG per size too.
        png.save(ASSETS / f"icon_{suffix}.png")

    contents = {
        "images": [
            {"idiom": "mac", "size": f"{p}x{p}", "scale": f"{sc}x",
             "filename": f"icon_{p}x{p}" + ("@2x" if sc == 2 else "") + ".png"}
            for p, sc in variants
        ],
        "info": {"author": "xcode", "version": 1},
    }
    import json
    (ASSETS / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")

    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)],
                   check=True)
    print(f"wrote {ICNS} ({ICNS.stat().st_size} bytes)")
    print(f"wrote {len(variants)} PNGs to {ASSETS}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
