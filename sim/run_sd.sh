#!/usr/bin/env bash
# SD driver test: builds fw_sd/sd_main.c with the firmware's sd.c and runs it
# in tb_soc.v against sd_card_model.v (SD_MODEL). Checks the High Speed
# switch, streamed reads across calls, non-sequential reads, recovery from
# a read left open, every byte read, and the card's MOSI setup time; prints
# the cycles for 8 sectors at 36 and 18 MHz. Extra arguments go to iverilog,
# e.g. -DSD_TODLY=8.0 for a faster card. Pass +fst for a waveform dump.
set -euo pipefail
cd "$(dirname "$0")"
FW=../firmware
CROSS=${CROSS:-riscv64-unknown-elf-}
mkdir -p fw_sd/build
${CROSS}gcc -march=rv32im_zba_zicbop_zicsr_zifencei_zicbom -mabi=ilp32 -Os -ffreestanding -fno-builtin \
    -nostdlib -nostartfiles -Wall -Wextra -I$FW -T $FW/link.ld -Wl,--gc-sections \
    $FW/crt0.S fw_sd/sd_main.c $FW/sd.c $FW/libc.c -lgcc -o fw_sd/build/sd.elf
${CROSS}objcopy -O binary fw_sd/build/sd.elf fw_sd/build/sd.bin
python3 $FW/makehex.py fw_sd/build/sd.bin fw_sd/build/ufm_init.hex 19456 4
PRIM=${GOWIN_HOME:-$HOME/gowin/IDE}/simlib/gw1n/prim_sim.v   # Gowin's primitives
iverilog -g2012 -s tb -I. -I../rtl -DSD_MODEL "$@" -o fw_sd/build/sd.vvp tb_soc.v ../rtl/soc.v ../rtl/hyperram.sv \
    ../rtl/gowin_dpb/dpb_8k32_64.v psram_model.v spi_flash_model.v sd_card_model.v "$PRIM"
cp ../rtl/vram_init0.hex ../rtl/vram_init1.hex ../rtl/vram_init2.hex ../rtl/usb_hid_host_rom.hex fw_sd/build/
cd fw_sd/build   # (the testbench reads its .hex files from the current directory)
vvp -n sd.vvp | grep -v "psram: CA=\|register write\|stored 32 bytes\|stored 128 bytes\|^video:"
