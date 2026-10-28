#!/usr/bin/env python3
"""Drives a running m9b program over the UART (115200 baud): screenshots
and keys, for testing without looking at the screen (the boot screen,
Tyrian, Descent).

  m9bctl.py shot OUT.png       ask for the screen (0x1C: the program dumps
                               its size, palette and pixels) and save it
  m9bctl.py keys SEQ [SEQ ...]    send keys: text as is, and <up> <down> <left>
                               <right> <enter> <esc> <space> <bs>, <wait:MS>
Options: --port DEVICE (default: the CP2102), --scale N (png upscale)
"""
import argparse
import glob
import os
import re
import select
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run  # noqa: E402  (default_port, set_raw, read_until)

KEYS = {"up": b"\x1b[A", "down": b"\x1b[B", "right": b"\x1b[C", "left": b"\x1b[D",
        "enter": b"\r", "esc": b"\x1b", "space": b" ", "bs": b"\x7f"}


def shot(fd, out, scale):
    from PIL import Image
    while True:   # drop whatever is waiting
        try:
            if not os.read(fd, 65536):
                break
        except BlockingIOError:
            break
    os.write(fd, b"\x1c")
    _, buf = run.read_until(fd, b"M9BSHOT\n", 10)
    if b"M9BSHOT\n" not in buf:
        sys.exit("no screenshot (is the program running?)")
    data = buf.split(b"M9BSHOT\n", 1)[1]
    end = time.time() + 60
    need = 4
    while time.time() < end:
        if need == 4 and len(data) >= 4:   # the size is known: the whole dump's length
            w, h = data[0] | data[1] << 8, data[2] | data[3] << 8
            need = 4 + 512 + w * h
        if len(data) >= need:
            break
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            data += os.read(fd, 65536)
    if len(data) < need:
        sys.exit(f"short screenshot: {len(data)} of {need} bytes")
    data = data[4:need]
    pal = []
    for i in range(256):
        c = data[2 * i] | data[2 * i + 1] << 8
        r, g, b = (c >> 11) & 31, (c >> 5) & 63, c & 31
        pal += [r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2]
    img = Image.frombytes("P", (w, h), data[512:])
    img.putpalette(pal)
    img = img.convert("RGB")
    if scale > 1:
        img = img.resize((w * scale, h * scale), Image.NEAREST)
    img.save(out)
    print(f"saved {out}")


def keys(fd, seqs):
    for seq in seqs:
        for tok in re.split(r"(<[^>]+>)", seq):
            if not tok:
                continue
            m = re.fullmatch(r"<wait:(\d+)>", tok)
            if m:
                time.sleep(int(m.group(1)) / 1000)
            elif tok.startswith("<") and tok[1:-1] in KEYS:
                os.write(fd, KEYS[tok[1:-1]])
                time.sleep(0.25)
            else:
                for ch in tok:
                    os.write(fd, ch.encode())
                    time.sleep(0.25)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["shot", "keys"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--port", default=None)
    ap.add_argument("--scale", type=int, default=2)
    a = ap.parse_args()
    port = a.port or run.default_port()
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    run.set_raw(fd, 115200)
    if a.cmd == "shot":
        shot(fd, a.args[0] if a.args else "shot.png", a.scale)
    else:
        keys(fd, a.args)


if __name__ == "__main__":
    main()
