#!/usr/bin/env python3
"""Turns rendered music into what the ports stream: 24 kHz 16-bit mono WAV
(OPL music is mono anyway), at a common loudness: a linear gain to the
target integrated loudness (EBU R128, default -18 LUFS, about where the
Tyrian and Doom renders sit), capped so the peak stays at -1 dBFS. No
compression or limiting: the music keeps its dynamics.

Usage: finish.py IN.WAV OUT.WAV [--target LUFS] [--rate HZ] [--gain DB]
  --gain DB   apply this gain instead of measuring (pieces that play
              together, as System Shock's layers, share one: measure() on
              the whole set)
Needs ffmpeg."""
import argparse
import re
import subprocess


def measure(path):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af",
                        "pan=mono|c0=0.5*c0+0.5*c1,ebur128=peak=sample", "-f", "null", "-"],
                       capture_output=True, text=True, check=True).stderr
    summary = r[r.rindex("Summary:"):]
    loud = float(re.search(r"I:\s+(-?[\d.]+) LUFS", summary).group(1))
    peak = float(re.search(r"Peak:\s+(-?[\d.inf]+) dBFS", summary).group(1))
    return loud, peak


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inp")
    ap.add_argument("out")
    ap.add_argument("--target", type=float, default=-18.0)
    ap.add_argument("--rate", type=int, default=24000)
    ap.add_argument("--gain", type=float)
    a = ap.parse_args()
    if a.gain is not None:
        loud, peak, gain = float("nan"), float("nan"), a.gain
    else:
        loud, peak = measure(a.inp)
        gain = min(a.target - loud, -1.0 - peak)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", a.inp, "-af",
                    f"pan=mono|c0=0.5*c0+0.5*c1,volume={gain:.2f}dB", "-ar", str(a.rate),
                    "-c:a", "pcm_s16le", "-fflags", "+bitexact", "-map_metadata", "-1", a.out], check=True)
    print(f"{a.out}: {loud:.1f} LUFS, peak {peak:.1f} dBFS, gain {gain:+.1f} dB -> "
          f"{loud + gain:.1f} LUFS")


if __name__ == "__main__":
    main()
