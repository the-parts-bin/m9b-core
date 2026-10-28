#!/usr/bin/env python3
"""Write files to the board's SD card over the UART, without taking the card
out: uploads sdput.bin with ../run.py (which resets the board), then sends
the files (protocol: see sdput.c). Each file is read back on the board and
its checksum compared.

Usage: sdput.py sync DIR [--dry-run] [--keep PATH ...]
                                            bring the card up to date with
                                            DIR, a card's file tree on the PC
                                            (../../../sdcard/out/card): sends
                                            what is missing or differs
       sdput.py put LOCAL REMOTE [...]      copy files (pairs; REMOTE like
                                            DOOMS/MUSIC/D_E1M1.WAV)
       sdput.py ls [DIR]                    list a directory (default: root)
       sdput.py rm REMOTE [...]             delete files (or empty directories)
       sdput.py rawtest                     write test on the card's last sector
Options: --port DEVICE, --baud 921600 (the transfer rate), --no-load (sdput
is already running on the board), --to DIR (put: copy into DIR, a card's
file tree on the PC, instead of the board; ../../../sdcard uses this)

sync compares each file's size and time with the card's (sdput stamps the
files it writes with the PC file's time, as rsync does); a file of the same
size with another time (one written before sdput set times) is checksummed
on the board, and only sent if it differs. Nothing on the card is deleted.
Files the games rewrite with their settings are only sent when missing:
U7/exult.cfg, and any --keep PATH.
"""
import argparse
import itertools
import os
import select
import shutil
import struct
import subprocess
import sys
import termios
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import run  # noqa: E402  (the loader's helpers: rate switching, reading)

OPEN, CLOSE, RAWTEST, LIST, COMMIT, SUM, TIME, QUIT, DELETE = range(0xFFF0, 0xFFF9)
BLOCK = 2048
WINDOW = 64            # blocks per window (sdput.c)
KEEP = ["U7/exult.cfg"]   # rewritten by the game: only sent when missing


def checksum(data, a=1, s=0):
    """run.checksum (the loader's Fletcher-style sum), fast: after n bytes,
    a grows by their sum and s by n * a plus the sum of the running sums."""
    s += len(data) * a + sum(itertools.accumulate(data))
    a += sum(data)
    a &= 0xFFFFFFFF
    s &= 0xFFFFFFFF
    return a, s


def digest(a, s):
    return (a ^ (s << 16) ^ (s >> 16)) & 0xFFFFFFFF


def frame(block, payload):
    """0xA5, block, length, payload, and a checksum over block, length and
    payload (sdput.c; the loader's frames leave the header out)."""
    head = struct.pack("<HH", block, len(payload))
    return b"\xa5" + head + payload + struct.pack("<I", digest(*checksum(head + payload)))


def reply_line(fd, rest, timeout):
    """The rest of a reply line after its first character."""
    if b"\n" not in rest:
        more, _ = run.read_until(fd, b"\n", timeout)
        rest += more or b""
    return rest.split(b"\n")[0].decode(errors="replace").strip()


def read_reply(fd, timeout):
    """The board's first 'K', 'N' or 'E' (None on timeout), and what followed."""
    buf = b""
    end = time.time() + timeout
    while True:
        for i, ch in enumerate(buf):
            if ch in b"KNE":
                return chr(ch), buf[i + 1:]
        left = end - time.time()
        if left <= 0:
            return None, b""
        r, _, _ = select.select([fd], [], [], left)
        if r:
            buf += os.read(fd, 4096)


def command(fd, block, payload, timeout=5.0):
    """Sends a frame until it isn't refused ('N'); returns ('K' or 'E', the rest)."""
    fr = frame(block, payload)
    for attempt in range(20):
        os.write(fd, fr)
        c, rest = read_reply(fd, timeout)
        if c in ("K", "E"):
            return c, rest
        time.sleep(0.02)   # let the board drain
        termios.tcflush(fd, termios.TCIFLUSH)
    sys.exit(f"no answer to frame {block:#x}")


def fat_time(mtime):
    """FAT's date and time fields (UTC, 2 s steps) for a PC file time."""
    t = time.gmtime(max(mtime, 315532800))   # FAT starts in 1980
    return ((t.tm_year - 1980) << 9 | t.tm_mon << 5 | t.tm_mday,
            t.tm_hour << 11 | t.tm_min << 5 | t.tm_sec // 2)


def list_dir(fd, path):
    """{lower-case name: (is_dir, size, date, time, name)}, or None if path
    doesn't exist."""
    c, rest = command(fd, LIST, path.encode())
    if c == "E":
        reply_line(fd, rest, 2)
        return None
    buf = rest
    while not buf.endswith(b".\n"):
        more, _ = run.read_until(fd, b".\n", 5.0)
        if more is None:
            break
        buf += more
    entries = {}
    for line in buf.decode(errors="replace").split("\n"):
        p = line.split(" ", 4)
        if len(p) == 5 and p[0] in ("d", "f"):
            entries[p[4].lower()] = (p[0] == "d", int(p[1]), int(p[2]), int(p[3]), p[4])
    return entries


def send_frames(fd, data, pending):
    """Sends the blocks in pending back to back until the board has
    acknowledged each ('k' and the block number); 'N' (a bad frame) or
    silence: they go again."""
    pending = set(pending)
    for attempt in range(20):
        os.write(fd, b"".join(frame(b, data[b * BLOCK:(b + 1) * BLOCK]) for b in sorted(pending)))
        termios.tcdrain(fd)
        buf = b""
        end = time.time() + 0.5
        while pending and time.time() < end:
            r, _, _ = select.select([fd], [], [], max(0.0, end - time.time()))
            if not r:
                continue
            buf += os.read(fd, 4096)
            while buf:
                if buf[0] == ord("k"):
                    if len(buf) < 3:
                        break
                    pending.discard(buf[1] | buf[2] << 8)
                    buf = buf[3:]
                    end = time.time() + 0.5
                else:   # 'N' (a bad frame: resent below) or noise
                    buf = buf[1:]
        if not pending:
            return
        time.sleep(0.02)
        termios.tcflush(fd, termios.TCIFLUSH)
    sys.exit(f"blocks {sorted(pending)[:5]}...: no answer")


def send_window(fd, data, first, count):
    """Blocks first .. first + count - 1, then COMMIT, which writes them. A
    block the board lost again after acknowledging it (a later bad frame
    landed in its slot) is reported missing: sent again."""
    send_frames(fd, data, range(first, first + count))
    for attempt in range(10):
        c, rest = command(fd, COMMIT, struct.pack("<H", count), timeout=30.0)
        if c == "K":
            return
        line = reply_line(fd, rest, 2)
        if not line.startswith("missing block "):
            break
        send_frames(fd, data, [int(line.split()[-1])])
    sys.exit(f"commit at block {first}: {line}")


def set_time(fd, remote, mtime):
    c, rest = command(fd, TIME, struct.pack("<HH", *fat_time(mtime)) + remote.encode())
    if c != "K":
        sys.exit(f"{remote}: time: " + reply_line(fd, rest, 2))


def put_file(fd, local, remote):
    data = open(local, "rb").read()
    if len(data) > 0xFFF0 * BLOCK:
        sys.exit(f"{local}: too big")
    c, rest = command(fd, OPEN, remote.encode())
    if c == "E":
        sys.exit(f"{remote}: " + reply_line(fd, rest, 2))
    t0 = time.time()
    blocks = (len(data) + BLOCK - 1) // BLOCK
    for first in range(0, blocks, WINDOW):
        send_window(fd, data, first, min(WINDOW, blocks - first))
        done = min(len(data), (first + WINDOW) * BLOCK)
        print(f"\r  {remote}: {done // 1024} / {len(data) // 1024} KB, "
              f"{done / (time.time() - t0) / 1024:.0f} KB/s", end="", file=sys.stderr, flush=True)
    c, rest = command(fd, CLOSE, b"", timeout=60.0)
    line = reply_line(fd, rest, 60.0)
    dt = time.time() - t0
    want = f"{digest(*checksum(data)):08x}"
    if c != "K" or line != want:
        sys.exit(f"\n{remote}: check failed ({c} {line}, want {want})")
    set_time(fd, remote, os.path.getmtime(local))
    print(f"\r  {remote}: {len(data)} bytes in {dt:.1f} s ({len(data) / max(dt, 1e-3) / 1024:.0f} KB/s), "
          "verified", file=sys.stderr)


def sync(fd, root, keep, dry_run):
    """Sends what in root is missing on the card or differs (sync, above)."""
    keep = {k.lower() for k in KEEP + keep}
    todo, same, adopted, kept = [], 0, 0, 0
    for d, dirs, files in os.walk(root):
        dirs.sort()
        rel_dir = os.path.relpath(d, root).replace(os.sep, "/")
        remote_dir = "" if rel_dir == "." else rel_dir
        entries = list_dir(fd, remote_dir or "/") or {}
        for name in sorted(files):
            local = os.path.join(d, name)
            remote = f"{remote_dir}/{name}" if remote_dir else name
            st = os.stat(local)
            e = entries.get(name.lower())
            if e is None or e[0]:
                todo.append((local, remote, st.st_size, "new"))
            elif remote.lower() in keep:
                kept += 1
            elif e[1] == st.st_size and (e[2], e[3]) == fat_time(st.st_mtime):
                same += 1
            elif e[1] != st.st_size:
                todo.append((local, remote, st.st_size, "changed"))
            else:   # same size, another time: compare the contents
                c, rest = command(fd, SUM, remote.encode(), timeout=120.0)
                line = reply_line(fd, rest, 120.0)
                if c == "K" and line == f"{digest(*checksum(open(local, 'rb').read())):08x}":
                    if not dry_run:
                        set_time(fd, remote, st.st_mtime)
                    adopted += 1
                else:
                    todo.append((local, remote, st.st_size, "changed"))
    total = sum(t[2] for t in todo)
    print(f"sync {root}: {same} up to date, {adopted} the same (times set), {kept} kept as the games wrote "
          f"them; {len(todo)} to send, {total / 1e6:.1f} MB (about {total / 87e3 / 60:.0f} min)", file=sys.stderr)
    for local, remote, size, why in todo:
        if dry_run:
            print(f"  {why:7s} {remote} ({size} bytes)")
        else:
            put_file(fd, local, remote)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["sync", "put", "ls", "rm", "rawtest"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--port", default=None)
    ap.add_argument("--baud", type=int, default=921600, choices=[r for r, _ in run.RATES])
    ap.add_argument("--no-load", action="store_true")
    ap.add_argument("--to", metavar="DIR")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--keep", action="append", default=[], metavar="PATH")
    a = ap.parse_args()
    if a.cmd == "put" and (not a.args or len(a.args) % 2):
        sys.exit("put needs LOCAL REMOTE pairs")
    if a.cmd == "rm" and not a.args:
        sys.exit("rm needs the files to delete")
    if a.cmd == "sync" and (len(a.args) != 1 or not os.path.isdir(a.args[0])):
        sys.exit("sync needs one directory")
    if a.to:
        if a.cmd != "put":
            sys.exit("--to works with put only")
        for local, remote in zip(a.args[0::2], a.args[1::2]):
            dst = os.path.join(a.to, remote)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(local, dst)   # with its time: sync compares times
        print(f"  {len(a.args) // 2} files copied to {a.to}", file=sys.stderr)
        return
    port = a.port or run.default_port()

    fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
    fd = run.switch_rate(fd, port, 115200)
    if not a.no_load:
        subprocess.run(["make", "-s", "-C", HERE], check=True)   # sdput.bin, if it changed
        os.close(fd)
        subprocess.run([sys.executable, os.path.join(HERE, "..", "run.py"), os.path.join(HERE, "build", "sdput.bin"),
                        "--port", port, "--no-terminal"], check=True)
        fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
        run._current_rate[0] = None
        fd = run.switch_rate(fd, port, 115200)
        # Its banner ("sdput ready") may be half gone by now: it waits for
        # the handshake below either way.
        run.read_until(fd, b"sdput ready", 1.0)
    div = dict(run.RATES)[a.baud]
    os.write(fd, b"\x1bSDPUT" + bytes([div]))
    got, buf = run.read_until(fd, b"READY\n", 3.0)
    if got is None:
        sys.exit(f"no READY (got {buf!r})")
    fd = run.switch_rate(fd, port, a.baud)
    time.sleep(0.03)

    try:
        if a.cmd == "rawtest":
            c, rest = command(fd, RAWTEST, b"")
            print(c, reply_line(fd, rest, 5))
        elif a.cmd == "ls":
            entries = list_dir(fd, a.args[0] if a.args else "/")
            if entries is None:
                sys.exit("ls: no such directory")
            for is_dir, size, date, tm, name in sorted(entries.values(), key=lambda e: e[4].lower()):
                stamp = (f"{(date >> 9) + 1980:04d}-{date >> 5 & 15:02d}-{date & 31:02d} "
                         f"{tm >> 11:02d}:{tm >> 5 & 63:02d}:{(tm & 31) * 2:02d}")
                print(f"{'d' if is_dir else 'f'} {size:10d} {stamp} {name}")
        elif a.cmd == "rm":
            for remote in a.args:
                c, rest = command(fd, DELETE, remote.encode())
                if c != "K":
                    sys.exit(f"rm {remote}: {reply_line(fd, rest, 2)}")
                print(f"  {remote} deleted", file=sys.stderr)
        elif a.cmd == "sync":
            sync(fd, a.args[0], a.keep, a.dry_run)
        else:
            for local, remote in zip(a.args[0::2], a.args[1::2]):
                put_file(fd, local, remote)
    finally:
        try:   # the board back to 115200 at once (else after 3 s of silence)
            os.write(fd, frame(QUIT, b""))
            read_reply(fd, 1.0)
        except OSError:
            pass


if __name__ == "__main__":
    main()
