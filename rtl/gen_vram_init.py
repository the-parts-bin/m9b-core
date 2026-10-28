#!/usr/bin/env python3
# Writes vram_init0/1/2.hex, the initial contents of the video RAM's three
# 512-word banks (rtl/vram.v, 1536 x 32-bit words in all, $readmemh
# format):
#   words    0..511  : font, 128 characters x 16 rows x 8 bits (byte
#                      address char * 16 + row), taken from the old font
#                      ROM's init values in gowin_prom/font_rom.v
#   words  512..639  : palette, 256 x RGB565 (entry i at byte 0x800 + 2 i):
#                      xterm-style -- 16 CGA colours, a 6x6x6 cube, a
#                      24-step grey ramp
#   words  640..1359 : per-line table, 720 entries, all 0 (blank lines)
#   words 1360..1535 : unused
import os
import re

here = os.path.dirname(os.path.abspath(__file__))

rom = open(os.path.join(here, "gowin_prom/font_rom.v")).read()
font = bytearray(2048)
for idx, val in re.findall(r"INIT_RAM_([0-9A-F]{2}) = 256'h([0-9A-F]{64});", rom):
    base = int(idx, 16) * 32
    chunk = int(val, 16).to_bytes(32, "big")[::-1]   # address 0 = rightmost byte
    font[base:base + 32] = chunk

def rgb565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)

cga = [(0, 0, 0), (170, 0, 0), (0, 170, 0), (170, 85, 0), (0, 0, 170), (170, 0, 170),
       (0, 170, 170), (170, 170, 170), (85, 85, 85), (255, 85, 85), (85, 255, 85),
       (255, 255, 85), (85, 85, 255), (255, 85, 255), (85, 255, 255), (255, 255, 255)]
levels = [0, 95, 135, 175, 215, 255]
palette = [rgb565(*c) for c in cga]
palette += [rgb565(levels[r], levels[g], levels[b])
            for r in range(6) for g in range(6) for b in range(6)]
palette += [rgb565(8 + 10 * i, 8 + 10 * i, 8 + 10 * i) for i in range(24)]
assert len(palette) == 256

words = [0] * 1536
for i in range(512):
    words[i] = int.from_bytes(font[4 * i:4 * i + 4], "little")
for i in range(128):
    words[512 + i] = palette[2 * i] | (palette[2 * i + 1] << 16)

for bank in range(3):
    with open(os.path.join(here, f"vram_init{bank}.hex"), "w") as f:
        for w in words[512 * bank:512 * (bank + 1)]:
            f.write(f"{w:08x}\n")
