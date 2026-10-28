#!/usr/bin/env bash
# Video/audio path simulation (tb_video.v), without the CPU.
set -euo pipefail
cd "$(dirname "$0")"
PRIM=${GOWIN_HOME:-$HOME/gowin/IDE}/simlib/gw1n/prim_sim.v   # Gowin's primitives
cp ../rtl/vram_init0.hex ../rtl/vram_init1.hex ../rtl/vram_init2.hex .
iverilog -g2012 -s tb -o video.vvp tb_video.v ../rtl/video_engine.v ../rtl/vram.v ../rtl/hyperram.sv \
    ../rtl/gowin_dpb/dpb_8k32_64.v psram_model.v "$PRIM"
vvp -n video.vvp "$@" | grep -v "psram: CA=\|register write\|stored 32 bytes\|stored 128 bytes\|dumping is suppressed"
