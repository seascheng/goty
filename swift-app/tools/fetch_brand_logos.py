#!/usr/bin/env python3
"""One-shot refresh: official color logos for Assets/AgentIcons.

Sources, in order of preference:
  - Iconify logos:* sets (multi-color OFFICIAL marks)
  - Iconify simple-icons:* + brand hex (single-color official shape)
  - Local files (omp: the oh-my-pi favicon, a real color mark)

Rendering: qlmanage rasterizes SVG (WebKit); near-white connected
background is flooded transparent; alpha bbox is centered on a square
canvas with 12% padding; rasterized to the @2x/@3x/@4x ladder
(36/54/72px for the 18pt slot).
"""
import subprocess, sys, os
from pathlib import Path

ASSETS = Path(__i_file__ if False else "/Users/seascheng/Downloads/ai_project/goty/swift-app/Assets/AgentIcons")
TMP = Path("/tmp/goty-icons")
TMP.mkdir(exist_ok=True)
OMP_FAV = "/Users/seascheng/Downloads/ai_project/oh-my-pi/packages/collab-web/public/favicon-512x512.png"

# kind -> iconify path (prefix/name) + optional color override for
# single-color sets whose official color is black (invisible on dark).
PLAN = {
    "claude":   ("simple-icons/claude", "#D97757"),
    "codex":    ("logos/codex", None),
    "gemini":   ("logos/google-gemini", None),
    "copilot":  ("logos/github-copilot", None),
    "qwen":     ("simple-icons/qwen", "#613CED"),
    "kimi":     ("simple-icons/kimi", "#8B5CF6"),
    "cursor":   ("logos/cursor", None),
    "cline":    ("simple-icons/cline", "#3B82F6"),
    "amp":      ("simple-icons/amp", None),
    "opencode": ("simple-icons/opencode", None),
    "grok":     ("logos/grok", None),
    "goose":    ("logos/goose", None),
    "droid":    ("logos/droid", None),
}

def fetch_svg(kind, path, color):
    url = f"https://api.iconify.design/{path}.svg"
    if color:
        import urllib.parse
        url += "?color=" + urllib.parse.quote(color)
    out = TMP / f"{kind}.svg"
    r = subprocess.run(["curl", "-sL", "--max-time", "20", "-o", str(out),
                        "-w", "%{http_code}", url], capture_output=True, text=True)
    ok = r.stdout.strip() == "200" and out.exists() and out.stat().st_size > 50
    return (out if ok else None), r.stdout.strip()

def render_png(svg_path):
    out = TMP / (svg_path.stem + ".raw.png")
    subprocess.run(["qlmanage", "-t", "-s", "512", "-o", str(TMP), str(svg_path)],
                   capture_output=True)
    produced = TMP / (svg_path.stem + ".svg.png")
    if produced.exists():
        os.replace(produced, out)
        return out
    return None

def whiteness_to_alpha(img):
    """Flood-fill the connected near-white border to transparency."""
    from PIL import Image
    from collections import deque
    im = img.convert("RGBA")
    w, h = im.size
    px = im.load()
    def near_white(p):
        return p[0] > 242 and p[1] > 242 and p[2] > 242
    seen = [[False]*w for _ in range(h)]
    q = deque()
    for x in range(w):
        for y in (0, h-1):
            if near_white(px[x, y]) and not seen[y][x]:
                q.append((x, y)); seen[y][x] = True
    for y in range(h):
        for x in (0, w-1):
            if near_white(px[x, y]) and not seen[y][x]:
                q.append((x, y)); seen[y][x] = True
    while q:
        x, y = q.popleft()
        px[x, y] = (255, 255, 255, 0)
        for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)):
            nx, ny = x+dx, y+dy
            if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and near_white(px[nx, ny]):
                seen[ny][nx] = True
                q.append((nx, ny))
    return im

def normalize(src, dst_stem, pad=0.12, keep_frame=False):
    from PIL import Image
    im = Image.open(src).convert("RGBA")
    if not keep_frame:
        im = whiteness_to_alpha(im)
        bbox = im.getbbox()
        if bbox:
            im = im.crop(bbox)
        side = int(max(im.size) * (1 + pad*2))
        canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        canvas.paste(im, ((side - im.width)//2, (side - im.height)//2), im)
        im = canvas
    for scale, px in ((2, 36), (3, 54), (4, 72)):
        out = ASSETS / f"{dst_stem}@{scale}x.png"
        im.resize((px, px), Image.LANCZOS).save(out)
    print(f"  {dst_stem}: OK ({im.size[0]}px src)")

def is_color(png):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        from gen_agent_icons import is_monochrome
        return not is_monochrome(Path(png))
    except Exception:
        return None

def main():
    only = sys.argv[1:] or None
    for kind, (path, color) in PLAN.items():
        if only and kind not in only:
            continue
        svg, code = fetch_svg(kind, path, color)
        if svg is None:
            print(f"  {kind}: FETCH FAIL {code} ({path})")
            continue
        png = render_png(svg)
        if png is None:
            print(f"  {kind}: RENDER FAIL")
            continue
        normalize(png, kind)
    # omp: local official favicon (already a framed app icon)
    if not only or "omp" in only:
        normalize(OMP_FAV, "omp", keep_frame=True)
    # pi: same upstream (oh-my-pi π) — the pi CLI ships this mark.
    if not only or "pi" in only:
        normalize(OMP_FAV, "pi", keep_frame=True)
    print("done")

if __name__ == "__main__":
    main()
