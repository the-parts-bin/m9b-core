#!/usr/bin/env python3
"""Upload a program to the m9b board over the UART and run it, then act as a
serial terminal (Ctrl-] quits). Protocol: see firmware/loader.h.

Usage: run.py program.bin [--addr 0x800000] [--port DEVICE]
                          [--baud 3000000] [--no-terminal | --listen SECONDS]

The port must be free (close tio first). By default it is the external
USB-serial adapter on header J5 if one is plugged in (CP210x or FTDI FT232),
else the board's own BL702 (its second interface; the first is JTAG).
"""
import argparse
import glob
import os
import select
import struct
import sys
import termios
import time
import tty

SPEEDS = {115200: termios.B115200, 460800: termios.B460800, 921600: termios.B921600,
          1000000: termios.B1000000, 1500000: termios.B1500000, 3000000: termios.B3000000}
# Transfer rates to try, fastest first, with the board's divider: its UART
# counts CPU clock cycles (36 MHz, firmware/clock.h), rounded.
CPU_HZ = 36_000_000
RATES = [(b, (CPU_HZ + b // 2) // b) for b in (3000000, 1500000, 1000000, 921600, 460800, 115200)]


def default_port():
    """The external adapter if present, else the BL702's UART interface.
    /dev/serial/by-id names, since ttyUSB numbers shift with plug order."""
    ids = sorted(glob.glob("/dev/serial/by-id/*"))
    for pattern in ("CP210", "FT232", "FTDI"):
        for p in ids:
            if pattern in p:
                return p
    for p in ids:
        if "SIPEED" in p and "if01" in p:
            return p
    return "/dev/ttyUSB1"


def set_raw(fd, baud):
    attr = termios.tcgetattr(fd)
    attr[0] = 0                                               # iflag
    attr[1] = 0                                               # oflag
    attr[2] = termios.CS8 | termios.CREAD | termios.CLOCAL    # cflag
    attr[3] = 0                                               # lflag
    attr[4] = attr[5] = SPEEDS[baud]
    attr[6][termios.VMIN] = 0
    attr[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attr)


_current_rate = [None]


def switch_rate(fd, port, baud):
    """Change the line rate. The board's USB-serial chip (a BL702 emulating
    an FT2232) only applies a new rate when the port is opened, and then the
    rate set before that: set it, close, reopen, set it again (~20 ms).
    Nothing is done if the rate is already set."""
    if _current_rate[0] == baud:
        return fd
    _current_rate[0] = baud
    set_raw(fd, baud)
    os.close(fd)
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
    set_raw(fd, baud)
    termios.tcflush(fd, termios.TCIFLUSH)
    return fd


def read_until(fd, token, timeout):
    buf = b""
    end = time.time() + timeout
    while token not in buf:
        left = end - time.time()
        if left <= 0:
            return None, buf
        r, _, _ = select.select([fd], [], [], left)
        if r:
            buf += os.read(fd, 4096)
    return buf, buf


def read_ack(fd, timeout):
    """The board's first 'K' or 'N' (None on timeout), and what followed it."""
    buf = b""
    end = time.time() + timeout
    while True:
        for i, ch in enumerate(buf):
            if ch in b"KN":
                return bytes([ch]), buf[i + 1:]
        left = end - time.time()
        if left <= 0:
            return None, b""
        r, _, _ = select.select([fd], [], [], left)
        if r:
            buf += os.read(fd, 4096)


def checksum(data):
    a, b = 1, 0
    for v in data:
        a = (a + v) & 0xFFFFFFFF
        b = (b + a) & 0xFFFFFFFF
    return (a ^ (b << 16) ^ (b >> 16)) & 0xFFFFFFFF


def wait_for_prompt(fd, timeout):
    """After a reset: wait until the firmware has printed its last boot line
    (the SPI flash test) and a bit more, or until the timeout."""
    got, buf = read_until(fd, b"spi flash:", timeout)
    if got is not None:
        read_until(fd, b"\n", 1.0)
        time.sleep(0.1)
    else:
        print(f"(no boot banner after the reset; got {len(buf)} bytes)", file=sys.stderr)
    termios.tcflush(fd, termios.TCIFLUSH)


def frame(block, payload):
    """0xA5, block, length, payload, checksum (see firmware/loader.h)."""
    return struct.pack("<BHH", 0xA5, block, len(payload)) + payload + struct.pack("<I", checksum(payload))


def terminal(fd):
    print("-- terminal (Ctrl-] quits) --", file=sys.stderr)
    stdin = sys.stdin.fileno()
    old = termios.tcgetattr(stdin) if os.isatty(stdin) else None
    try:
        if old:
            tty.setraw(stdin)
        while True:
            r, _, _ = select.select([fd, stdin], [], [])
            if fd in r:
                data = os.read(fd, 4096)
                os.write(sys.stdout.fileno(), data)
            if stdin in r:
                data = os.read(stdin, 64)
                if b"\x1d" in data:
                    break
                os.write(fd, data)
    finally:
        if old:
            termios.tcsetattr(stdin, termios.TCSADRAIN, old)
        print("\r\n-- bye --", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("program")
    ap.add_argument("--addr", type=lambda s: int(s, 0), default=0x800000)
    ap.add_argument("--port", default=None, help="serial device (default: see above)")
    ap.add_argument("--baud", type=int, default=0, choices=[r for r, _ in RATES],
                    help="transfer rate (default: the fastest that works)")
    ap.add_argument("--no-terminal", action="store_true")
    ap.add_argument("--no-reset", action="store_true", help="don't reset the board first")
    ap.add_argument("--boot-wait", type=float, default=8.0,
                    help="seconds to wait for the firmware after the reset (it ends its boot with 'spi flash:')")
    ap.add_argument("--listen", type=float, default=0,
                    help="instead of the terminal, print the board's output for this many seconds")
    args = ap.parse_args()

    args.port = args.port or default_port()
    print(f"port {args.port}", file=sys.stderr)
    data = open(args.program, "rb").read()
    fd = os.open(args.port, os.O_RDWR | os.O_NOCTTY)
    fd = switch_rate(fd, args.port, 115200)
    if not args.no_reset:
        # "\x1bM9BRESET" resets the board in hardware (rtl/uart.v), whatever
        # it runs; the firmware then needs a few seconds for its boot tests.
        os.write(fd, b"\x1bM9BRESET")
        wait_for_prompt(fd, args.boot_wait)

    rates = [r for r in RATES if not args.baud or r[0] == args.baud]
    if not args.baud and "CP210" in args.port:
        # The CP2102 has a fixed rate table: 921600 works (0 resends), 1M
        # and up don't.
        rates = [r for r in rates if r[0] <= 921600]
    BLOCK = 2048
    frames = [frame(0xFFFE, struct.pack("<II", args.addr, len(data)))]
    frames += [frame(i // BLOCK, data[i:i + BLOCK]) for i in range(0, len(data), BLOCK)]
    for baud, div in rates:
        termios.tcflush(fd, termios.TCIOFLUSH)
        os.write(fd, b"\x1bM9BLOAD" + bytes([div]))
        got, buf = read_until(fd, b"READY\n", 3.0)
        if got is None:
            sys.exit(f"no READY from the board (got {buf!r}); is the core firmware running?")
        fd = switch_rate(fd, args.port, baud)
        time.sleep(0.03)   # the board ignores the first 5 ms of line noise
        t0 = time.time()
        naks = 0
        failed = False
        rest = b""
        for k, fr in enumerate(frames):
            for attempt in range(30):
                os.write(fd, fr)
                ack, rest = read_ack(fd, 0.5)
                if ack == b"K":
                    break
                naks += 1
                if ack == b"N" and naks <= 5:
                    time.sleep(0.05)
                    r, _, _ = select.select([fd], [], [], 0)
                    more = os.read(fd, 256) if r else b""
                    print(f"  frame {k}: N {(rest + more).split(b'\\n')[0].decode(errors='replace')}", file=sys.stderr)
                elif ack is None and naks <= 5:
                    print(f"  frame {k}: no answer", file=sys.stderr)
                time.sleep(0.02)                 # let the board drain
                termios.tcflush(fd, termios.TCIFLUSH)
            else:
                failed = True
                break
        if failed:
            got, buf = None, b""
        elif b"\n" in rest:
            got, buf = True, rest
        else:
            got, buf = read_until(fd, b"\n", 3.0)
            buf = rest + buf
        dt = time.time() - t0
        fd = switch_rate(fd, args.port, 115200)
        reply = buf.split(b"\n")[0].decode(errors="replace").strip() if buf else "(nothing)"
        if got is not None and reply.startswith("OK"):
            print(f"sent {len(data)} bytes to 0x{args.addr:08x} at {baud} baud in {dt:.2f} s "
                  f"({len(data) / dt / 1024:.0f} KB/s), {naks} frames resent; board: {reply}",
                  file=sys.stderr)
            break
        print(f"{baud} baud failed after frame {k} of {len(frames)} ({naks} resends; board: {reply[:40]!r}), "
              "trying slower", file=sys.stderr)
        time.sleep(3.5)   # the board gives up after 3 s of silence
        termios.tcflush(fd, termios.TCIOFLUSH)
    else:
        sys.exit("upload failed at every rate")
    if args.listen:
        end = time.time() + args.listen
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
            if r:
                os.write(sys.stdout.fileno(), os.read(fd, 4096))
    elif not args.no_terminal:
        terminal(fd)


if __name__ == "__main__":
    main()
