#!/usr/bin/env python3
"""Generates assets.h for the boot screen (boot.c): the fonts, the UI palette
and the logo.

Fonts: Pixel Operator regular and bold (Jayvee Enaguas, CC0, fonts/), a
proportional pixel font drawn on a 16 px grid, rendered at 16 px without
antialiasing (pixel-exact) into tables for ASCII 32..126: an advance width
and 16 rows of up to 16 pixels per character (bit 15 leftmost).

The boot screen is an 8 bpp framebuffer: palette entries 0..15 are the UI
colours (UI_* in assets.h), 32..255 the logo's (quantized). The logo is a
chip with gold pins and a gradient "m9b", drawn at 4x and scaled down.

Usage: gen_assets.py OUT.h [PREVIEW.png]
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
LOGO = 128          # pixels, square
LOGO_BASE = 32      # first palette entry of the logo
LOGO_COLORS = 224

# UI colours, entries 0..15 (names become UI_<NAME> in assets.h).
UI = [
    ("BG",      (10, 14, 24)),
    ("TEXT",    (200, 208, 224)),
    ("DIM",     (100, 112, 140)),
    ("ACCENT",  (58, 208, 255)),
    ("OK",      (80, 224, 128)),
    ("BAD",     (255, 80, 96)),
    ("WARN",    (255, 208, 96)),
    ("SELBG",   (30, 58, 95)),
    ("WHITE",   (255, 255, 255)),
    ("HEAD",    (255, 154, 60)),
    ("LINE",    (42, 52, 80)),
    ("PANEL",   (16, 22, 36)),
    ("ACCENT2", (200, 110, 255)),
    ("C13",     (0, 0, 0)),
    ("C14",     (0, 0, 0)),
    ("C15",     (0, 0, 0)),
]


def rgb565(c):
    r, g, b = c[:3]
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def prop_font(path):
    """(advances, rows) for ASCII 32..126 of a pixel TTF at 16 px."""
    f = ImageFont.truetype(os.path.join(HERE, "fonts", path), 16)
    adv, rows = [], []
    for c in range(32, 127):
        w = int(round(f.getlength(chr(c))))
        assert w <= 16, (path, chr(c), w)
        img = Image.new("1", (16, 16), 0)
        d = ImageDraw.Draw(img)
        d.fontmode = "1"
        d.text((0, 0), chr(c), font=f, fill=1)
        px = img.load()
        adv.append(w)
        rows.append([sum(1 << (15 - x) for x in range(16) if px[x, y]) for y in range(16)])
    return adv, rows


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(size, stops, horizontal=False):
    """An RGB image of the given size with a diagonal (or horizontal) gradient."""
    w, h = size
    img = Image.new("RGB", size)
    px = img.load()
    for y in range(h):
        for x in range(w):
            t = x / (w - 1) if horizontal else (x + y) / (w + h - 2)
            for i in range(len(stops) - 1):
                t0, c0 = stops[i]
                t1, c1 = stops[i + 1]
                if t <= t1:
                    px[x, y] = lerp(c0, c1, (t - t0) / (t1 - t0))
                    break
    return img


def logo():
    S = 4 * LOGO
    bg = UI[0][1]
    img = Image.new("RGB", (S, S), bg)
    d = ImageDraw.Draw(img)

    # Pins: 7 per side, gold with a darker edge.
    body0, body1 = int(S * 0.19), int(S * 0.81)
    n, pin_w = 7, int(S * 0.045)
    span = body1 - body0
    for i in range(n):
        c = body0 + span * (i + 0.5) / n
        for (x0, y0, x1, y1) in [(c - pin_w / 2, S * 0.06, c + pin_w / 2, body0 + 8),
                                 (c - pin_w / 2, body1 - 8, c + pin_w / 2, S * 0.94),
                                 (S * 0.06, c - pin_w / 2, body0 + 8, c + pin_w / 2),
                                 (body1 - 8, c - pin_w / 2, S * 0.94, c + pin_w / 2)]:
            d.rounded_rectangle((x0, y0, x1, y1), radius=6, fill=(150, 112, 40))
            d.rounded_rectangle((x0 + 4, y0 + 4, x1 - 4, y1 - 4), radius=4, fill=(236, 190, 90))

    # Glow behind the body.
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).rounded_rectangle((body0 - 6, body0 - 6, body1 + 6, body1 + 6), radius=40, fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(18))
    img = Image.composite(Image.new("RGB", (S, S), (40, 120, 200)), img, glow.point(lambda v: v * 0.55))
    d = ImageDraw.Draw(img)

    # Body: a gradient border and a dark face.
    border = gradient((S, S), [(0.0, (58, 208, 255)), (0.5, (140, 120, 255)), (1.0, (255, 80, 200))])
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle((body0, body0, body1, body1), radius=36, fill=255)
    img.paste(border, (0, 0), mask)
    face = gradient((S, S), [(0.0, (30, 38, 62)), (1.0, (12, 16, 28))])
    mask = Image.new("L", (S, S), 0)
    m = 14
    ImageDraw.Draw(mask).rounded_rectangle((body0 + m, body0 + m, body1 - m, body1 - m), radius=26, fill=255)
    img.paste(face, (0, 0), mask)
    d = ImageDraw.Draw(img)
    # pin-1 dot
    d.ellipse((body0 + 34, body0 + 34, body0 + 58, body0 + 58), fill=(90, 104, 140))

    # "m9b" in a gradient, with a soft shadow.
    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", int(S * 0.21))
    text = "m9b"
    tb = d.textbbox((0, 0), text, font=font)
    tw, th = tb[2] - tb[0], tb[3] - tb[1]
    tx, ty = (S - tw) // 2 - tb[0], int(S * 0.44) - th // 2 - tb[1]
    tmask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(tmask).text((tx, ty), text, font=font, fill=255)
    shadow = tmask.filter(ImageFilter.GaussianBlur(6)).point(lambda v: v * 0.7)
    img = Image.composite(Image.new("RGB", (S, S), (0, 0, 0)), img, shadow)
    tgrad = gradient((S, S), [(0.0, (90, 230, 255)), (0.5, (170, 140, 255)), (1.0, (255, 110, 210))], horizontal=True)
    img.paste(tgrad, (0, 0), tmask)

    # "RV32IM" under it.
    small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf", int(S * 0.075))
    d = ImageDraw.Draw(img)
    sb = d.textbbox((0, 0), "RV32IM", font=small)
    d.text(((S - (sb[2] - sb[0])) // 2 - sb[0], int(S * 0.64)), "RV32IM", font=small, fill=(120, 136, 176))

    return img.resize((LOGO, LOGO), Image.LANCZOS)


def main():
    out = sys.argv[1]
    img = logo()
    if len(sys.argv) > 2:
        img.resize((LOGO * 3, LOGO * 3), Image.NEAREST).save(sys.argv[2])
    q = img.quantize(colors=LOGO_COLORS, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    pal = q.getpalette()[:3 * LOGO_COLORS]
    pal += [0] * (3 * LOGO_COLORS - len(pal))
    pix = [LOGO_BASE + p for p in q.tobytes()]

    palette = [rgb565(c) for _, c in UI]
    palette += [0] * (LOGO_BASE - len(palette))
    palette += [rgb565(pal[3 * i:3 * i + 3]) for i in range(LOGO_COLORS)]
    assert len(palette) == 256

    fonts = [("font_regular", prop_font("PixelOperator.ttf")), ("font_bold", prop_font("PixelOperator-Bold.ttf"))]
    with open(out, "w") as f:
        f.write("// Generated by gen_assets.py: font, palette and logo for boot.c.\n")
        f.write("#ifndef ASSETS_H\n#define ASSETS_H\n#include <stdint.h>\n\n")
        for i, (name, _) in enumerate(UI):
            f.write(f"#define UI_{name} {i}u\n")
        f.write(f"\n#define LOGO_SIZE {LOGO}u\n\n")
        for name, (adv, rows) in fonts:
            f.write(f"static const uint8_t {name}_adv[95] = {{\n")
            for i in range(0, 95, 19):
                f.write("    " + ", ".join(str(v) for v in adv[i:i + 19]) + ",\n")
            f.write(f"}};\nstatic const uint16_t {name}_rows[95][16] = {{\n")
            for r in rows:
                f.write("    {" + ", ".join(f"0x{v:04x}" for v in r) + "},\n")
            f.write("};\n\n")
        f.write("static const uint16_t boot_palette[256] = {\n")
        for i in range(0, 256, 8):
            f.write("    " + ", ".join(f"0x{v:04x}" for v in palette[i:i + 8]) + ",\n")
        f.write("};\n\nstatic const uint8_t logo_pixels[LOGO_SIZE * LOGO_SIZE] = {\n")
        for i in range(0, len(pix), 16):
            f.write("    " + ", ".join(str(v) for v in pix[i:i + 16]) + ",\n")
        f.write("};\n\n#endif\n")


if __name__ == "__main__":
    main()
