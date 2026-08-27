#!/usr/bin/env python3
"""Compose images/themes.png — every non-hero screenshot tiled like
partially overlapping books: 2 rows of 4, cascading left-to-right,
row 2 offset like brickwork. Regenerate after replacing any screenshot:

    python3 images/make-collage.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

DIR = Path(__file__).resolve().parent

ORDER = [
    ["theme1.png", "theme2.png", "theme3.png", "theme4.png"],
    ["theme5.png", "theme6.png", "light.png", "blur.png"],
]

CARD_W, CARD_H = 768, 480  # 0.3 x 2560x1600
STEP_X = 356               # advance per card -> 46% of each card stays visible
STAGGER_Y = 8              # each card sits slightly lower than its neighbour
ROW_DX = 178               # row 1 shifted right, brick-style
ROW_OVER = 56              # vertical overlap between rows
PAD = 64
RADIUS = 16
BORDER = (255, 255, 255, 36)
SHADOW_OFFSET = (0, 14)
SHADOW_BLUR = 22
SHADOW_ALPHA = 120
BG_TOP = (0x1A, 0x1B, 0x20)
BG_BOTTOM = (0x26, 0x27, 0x2D)

ROW_H = CARD_H + STAGGER_Y * 3
W = PAD + ROW_DX + CARD_W + STEP_X * 3 + PAD
H = PAD + ROW_H + (ROW_H - ROW_OVER) + PAD


def card_xy(row: int, i: int) -> tuple[int, int]:
    x = PAD + row * ROW_DX + i * STEP_X
    y = PAD + row * (ROW_H - ROW_OVER) + i * STAGGER_Y
    return x, y


def load_card(name: str) -> Image.Image:
    return Image.open(DIR / name).convert("RGB").resize(
        (CARD_W, CARD_H), Image.LANCZOS
    )


def main() -> None:
    canvas = Image.new("RGB", (W, H))
    px = canvas.load()
    for y in range(H):  # vertical gradient backdrop
        t = y / (H - 1)
        c = tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM))
        for x in range(W):
            px[x, y] = c

    cards = [[load_card(n) for n in row] for row in ORDER]

    def paste(img: Image.Image, mask, xy):
        x, y = xy
        sil = Image.new("L", (CARD_W + 64, CARD_H + 64), 0)
        d = ImageDraw.Draw(sil)
        d.rounded_rectangle([32, 32, 32 + CARD_W, 32 + CARD_H], RADIUS, fill=SHADOW_ALPHA)
        sil = sil.filter(ImageFilter.GaussianBlur(SHADOW_BLUR))
        canvas.paste(
            Image.new("RGB", sil.size, (0, 0, 0)),
            (x - 32 + SHADOW_OFFSET[0], y - 32 + SHADOW_OFFSET[1]),
            sil,
        )
        canvas.paste(img, (x, y), mask)
        ImageDraw.Draw(canvas, "RGBA").rounded_rectangle(
            [x, y, x + CARD_W, y + CARD_H], RADIUS, outline=BORDER, width=2
        )


    mask = Image.new("L", (CARD_W, CARD_H), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, CARD_W, CARD_H], RADIUS, fill=255
    )

    for r, row in enumerate(cards):
        for i, img in enumerate(row):
            paste(img, mask, card_xy(r, i))

    out = DIR / "themes.png"
    canvas.save(out, optimize=True)

    # --- verify: size, card provenance, and that neighbours really overlap ---
    assert canvas.size == (W, H), canvas.size
    for r, row in enumerate(ORDER):
        for i in range(4):
            x, y = card_xy(r, i)
            probes = (24, 24), (300, 380 if r == 0 else 455)  # clear of row below
            for sx, sy in probes:
                assert px[x + sx, y + sy] == cards[r][i].load()[sx, sy], (r, i, sx, sy)
            if i < 3:  # right part of this card is covered by the next card
                cov = px[x + 500, y + 240]
                exp = cards[r][i + 1].load()[500 - STEP_X, 240 - STAGGER_Y]
                assert cov == exp, (r, i)
    print(f"{out}  {W}x{H}  {out.stat().st_size / 1e6:.2f} MB  checks passed")


if __name__ == "__main__":
    main()
