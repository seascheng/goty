#!/usr/bin/env python3
"""Second pass: re-render the gray/black stragglers.

Colors are the brands' own visual identities; where the official mark
is pure black (invisible on a dark sidebar) we use the closest brand
hue. Rendered via svglib (transparent canvas — qlmanage's white matte
was the halo source).
"""
import subprocess, re, sys
from pathlib import Path

TMP = Path("/tmp/goty-icons")
TMP.mkdir(exist_ok=True)
ASSETS = Path(__file__).resolve().parent.parent / "Assets" / "AgentIcons"

def fetch(url, out):
    r = subprocess.run(["curl", "-sL", "--max-time", "20", "-o", str(out),
                        "-w", "%{http_code}", url], capture_output=True, text=True)
    ok = r.stdout.strip() == "200" and Path(out).exists() and Path(out).stat().st_size > 50
    return Path(out) if ok else None

def tinted_svg(src, dst, color):
    t = Path(src).read_text(errors="replace")
    t = re.sub(r'<svg ', f'<svg fill="{color}" ', t, count=1)
    t = re.sub(r'fill="#000000"', f'fill="{color}"', t)
    t = re.sub(r'fill="#000"', f'fill="{color}"', t)
    t = re.sub(r'fill="black"', f'fill="{color}"', t)
    Path(dst).write_text(t)
    return Path(dst)

def svg_to_png(svg_path, out_png, size=512):
    from svglib.svglib import svg2rlg
    from reportlab.graphics import renderPM
    d = svg2rlg(str(svg_path))
    s = size / float(max(d.width, d.height))
    d.scale(s, s)
    d.width, d.height = float(size), float(size)
    # renderPM paints an opaque white matte; normalize() floods the
    # connected white border back to transparency.
    renderPM.drawToFile(d, str(out_png), fmt='PNG')
    return Path(out_png)

def normalize(src, dst_stem, pad=0.12, keep_frame=False, flood=True):
    from PIL import Image
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from fetch_brand_logos import whiteness_to_alpha
    im = Image.open(src).convert("RGBA")
    if not keep_frame:
        if flood:
            im = whiteness_to_alpha(im)
        bbox = im.getbbox()
        if bbox:
            im = im.crop(bbox)
        side = int(max(im.size) * (1 + pad*2))
        canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        canvas.paste(im, ((side - im.width)//2, (side - im.height)//2), im)
        im = canvas
    for scale, px in ((2, 36), (3, 54), (4, 72)):
        (ASSETS / f"{dst_stem}@{scale}x.png").unlink(missing_ok=True)
        im.resize((px, px), Image.LANCZOS).save(ASSETS / f"{dst_stem}@{scale}x.png")
    print(f"  {dst_stem}: done")

def audit(stem):
    from PIL import Image
    im = Image.open(ASSETS / f"{stem}@4x.png").convert("RGBA")
    op = [(r,g,b) for r,g,b,a in im.getdata() if a > 128]
    n = len(op)
    avg = [sum(c[i] for c in op)/n for i in range(3)]
    sat = max(avg) - min(avg)
    print(f"    audit {stem}: sat={sat:.0f} {'OK' if sat >= 18 else 'STILL GRAY'}")

JOBS = sys.argv[1:] or ["codex", "copilot", "cursor", "amp", "opencode",
                        "grok", "goose", "droid"]

for kind in JOBS:
    print(kind + ":")
    try:
        if kind == "codex":
            svg = fetch("https://api.iconify.design/simple-icons/openai.svg?color=%2310A37F", TMP/"codex.svg")
            normalize(svg_to_png(svg, TMP/"codex.png"), "codex")
        elif kind == "copilot":
            svg = fetch("https://api.iconify.design/simple-icons/githubcopilot.svg?color=%236E7EE8", TMP/"copilot2.svg")
            normalize(svg_to_png(svg, TMP/"copilot2.png"), "copilot")
        elif kind == "cursor":
            svg = fetch("https://api.iconify.design/simple-icons/cursor.svg?color=%235B6CF0", TMP/"cursor2.svg")
            normalize(svg_to_png(svg, TMP/"cursor2.png"), "cursor")
        elif kind == "amp":
            svg = fetch("https://api.iconify.design/simple-icons/amp.svg?color=%23D9C7A0", TMP/"amp2.svg")
            normalize(svg_to_png(svg, TMP/"amp2.png"), "amp")
        elif kind == "opencode":
            svg = fetch("https://api.iconify.design/simple-icons/opencode.svg?color=%2322D3EE", TMP/"opencode2.svg")
            normalize(svg_to_png(svg, TMP/"opencode2.png"), "opencode")
        elif kind == "grok":
            raw = fetch("https://commons.wikimedia.org/w/index.php?title=Special:Redirect/file/Grok_logo_(2023-2025).svg",
                        TMP/"grok-wm.svg")
            tinted = tinted_svg(raw, TMP/"grok-tint.svg", "#98A4B8")
            normalize(svg_to_png(tinted, TMP/"grok2.png"), "grok")
        elif kind == "goose":
            svg = fetch("https://api.iconify.design/selfhst/goose.svg", TMP/"goose2.svg")
            if svg is None:
                print("  goose: selfhst miss — keeping old mark")
                continue
            normalize(svg_to_png(svg, TMP/"goose2.png"), "goose")
        elif kind == "droid":
            normalize("/tmp/factory-fav", "droid")
    except Exception as e:
        print(f"  {kind}: ERROR {e}")
    audit(kind) if (ASSETS / f"{kind}@4x.png").exists() else None
