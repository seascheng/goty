#!/usr/bin/env python3
"""Refreshes Assets/AgentIcons/*.png from @lobehub/icons (mono variants).

Rationale (2026-08-27): the previous assets mixed tty7's re-blacked
marks with Simple Icons glyphs. @lobehub/icons is the single MIT-licensed
source that covers the agent catalog with consistent quality, and its
mono variants are single-color vector masks — rasterized, they classify
as tintable masks in gen_agent_icons.py and the sidebar tints them with
Chrome.theme.foreground (light icons on dark themes and vice versa).

The mono SVGs use fill="currentColor"; cairosvg defaults that to black,
which is exactly what the mask classifier expects.

Run inside the icon venv (build.sh provisions Pillow; this script also
needs cairosvg):
    tools/.icon-venv/bin/pip install cairosvg
    tools/.icon-venv/bin/python tools/fetch-agent-icons.py

Pinned version for reproducibility — bump deliberately and eyeball the
resulting diff (git tracks the PNGs).
"""

import io
import urllib.request
from pathlib import Path

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Assets" / "AgentIcons"

# @lobehub/icons mono slugs for the agent catalog. NOTE: these are the
# CDN slugs, not necessarily our kind keys — they match 1:1 today.
LOBEHUB = "https://cdn.jsdelivr.net/npm/@lobehub/icons-static-svg@1.94.0/icons"
KINDS = [
    "amp", "claude", "cline", "codex", "copilot", "cursor", "gemini",
    "goose", "grok", "kimi", "opencode", "pi", "qwen",
]
# omp is our own product glyph; droid has no lobehub entry — both keep
# the checked-in tty7 assets untouched.
KEEP_LOCAL = {"omp", "droid"}

# Rasterize at 16x the largest target (72px) so the bbox normalization
# and downscale filters have plenty of headroom.
RENDER = 288
SCALES = {2: 36, 3: 54, 4: 72}


def fetch_mono_png(kind: str) -> Image.Image:
    url = f"{LOBEHUB}/{kind}.svg"
    with urllib.request.urlopen(url) as resp:
        svg = resp.read()
    png = cairosvg.svg2png(bytestring=svg, output_width=RENDER,
                           output_height=RENDER)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def normalize_full_bleed(im: Image.Image) -> Image.Image:
    """Crop to the glyph's alpha box, then scale so the LONG side fills
    the canvas and center it — matches the tty7 full-bleed convention
    the existing assets use (alpha bbox ~= canvas)."""
    bbox = im.split()[3].getbbox()
    if bbox is None:
        raise SystemExit("empty glyph?")
    glyph = im.crop(bbox)
    w, h = glyph.size
    scale = RENDER / max(w, h)
    glyph = glyph.resize((round(w * scale), round(h * scale)),
                         Image.LANCZOS)
    canvas = Image.new("RGBA", (RENDER, RENDER), (0, 0, 0, 0))
    canvas.paste(glyph, ((RENDER - glyph.width) // 2,
                         (RENDER - glyph.height) // 2), glyph)
    return canvas


def main() -> None:
    for kind in KINDS:
        im = normalize_full_bleed(fetch_mono_png(kind))
        for scale, px in SCALES.items():
            out = ASSETS / f"{kind}@{scale}x.png"
            im.resize((px, px), Image.LANCZOS).save(out)
        bbox = im.split()[3].getbbox()
        print(f"{kind}: bbox {bbox} of {RENDER}")
    print(f"refreshed {len(KINDS)} kinds "
          f"({len(KEEP_LOCAL)} kept local: {sorted(KEEP_LOCAL)})")


if __name__ == "__main__":
    main()
