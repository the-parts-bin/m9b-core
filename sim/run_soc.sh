#!/usr/bin/env bash
# Whole-system simulation: builds sim/fw (the test program) and runs
# tb_soc.v. Pass +fst to also dump soc.fst for gtkwave.
set -euo pipefail
cd "$(dirname "$0")"
make -s -C fw
PRIM=${GOWIN_HOME:-$HOME/gowin/IDE}/simlib/gw1n/prim_sim.v   # Gowin's primitives
iverilog -g2012 -s tb -I. -I../rtl -o soc.vvp tb_soc.v ../rtl/soc.v ../rtl/hyperram.sv \
    ../rtl/gowin_dpb/dpb_8k32_64.v psram_model.v spi_flash_model.v "$PRIM"
cp fw/ufm_init.hex .
cp ../rtl/vram_init0.hex ../rtl/vram_init1.hex ../rtl/vram_init2.hex ../rtl/usb_hid_host_rom.hex .
vvp -n soc.vvp "$@" | grep -v "psram: CA=\|register write\|stored 32 bytes\|stored 128 bytes"
