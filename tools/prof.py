#!/usr/bin/env python3
"""Maps the PC-sample report lines (../runtime/trap.c) ("prof <addr> <n>") in a log to
functions of an ELF: prof.py ELF LOG. With --misaligned, the emulated misaligned accesses'
places instead ("misal <addr> <n>", profile builds)."""
import bisect, collections, re, subprocess, sys
args = [a for a in sys.argv[1:] if a != "--misaligned"]
tag = "misal" if "--misaligned" in sys.argv else "prof"
elf, log = args[0], args[1]
syms = []
for l in subprocess.run(["riscv64-unknown-elf-nm", "-n", elf], capture_output=True, text=True).stdout.splitlines():
    p = l.split()
    if len(p) == 3 and p[1] in "tTwW":
        syms.append((int(p[0], 16), p[2]))
addrs = [a for a, _ in syms]
c = collections.Counter(); tot = 0
for l in open(log, errors="ignore"):
    m = re.match(tag + r" ([0-9a-f]{8}) (\d+)", l)
    if m:
        a, n = int(m.group(1), 16), int(m.group(2))
        c[syms[bisect.bisect_right(addrs, a) - 1][1]] += n; tot += n
for f, n in c.most_common(25):
    print(f"{100 * n / tot:5.1f}% {f}")
