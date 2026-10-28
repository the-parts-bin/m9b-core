#!/usr/bin/env bash
# Build the firmware and FPGA bitstream, flash the board over JTAG, or
# both (default). Stops at the first failure.
#
# Flashing writes the FPGA's internal flash (persistent): the bitstream
# plus the firmware in the user flash, where the CPU runs it in place.
# The bitstream doesn't depend on the firmware, so --fw updates just the
# firmware without re-synthesizing (openFPGALoader still writes both).
#
# Usage: build.sh [--build | --flash | --fw | --both] [-h|--help]
#   --build   build firmware + bitstream only, don't flash
#   --flash   flash the existing bitstream and firmware, don't rebuild
#   --fw      rebuild the firmware only, then flash it with the existing
#             bitstream
#   --both    build then flash (default)

set -euo pipefail

usage() {
    echo "Usage: $0 [--build | --flash | --fw | --both] [-h|--help]"
    echo
    echo "  --build   build firmware + bitstream only, don't flash"
    echo "  --flash   flash the existing bitstream and firmware, don't rebuild"
    echo "  --fw      rebuild the firmware only, then flash it with the existing bitstream"
    echo "  --both    build then flash (default)"
}

MODE=both
case "${1-}" in
    ""|--both)   MODE=both ;;
    --build)     MODE=build ;;
    --flash)     MODE=flash ;;
    --fw)        MODE=fw ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
esac
if [ "$#" -gt 1 ]; then
    echo "Too many arguments" >&2
    usage >&2
    exit 1
fi

cd "$(dirname "$0")"

GOWIN_SH=tools/gw_sh.sh   # the Gowin IDE: $GOWIN_HOME, default ~/gowin/IDE
BITSTREAM=impl/pnr/core.fs
FIRMWARE=firmware/firmware.bin
SYN_LOG=impl/build.log

if [ "$MODE" = fw ]; then
    echo "== building firmware =="
    make -C firmware
fi

if [ "$MODE" = build ] || [ "$MODE" = both ]; then
    echo "== 1/2: building firmware =="
    make -C firmware

    echo
    echo "== 2/2: synthesizing + place&route + bitstream =="
    mkdir -p impl
    "$GOWIN_SH" build.tcl 2>&1 | tee "$SYN_LOG"

    if grep -qE "^ERROR " "$SYN_LOG"; then
        echo "Gowin reported errors, see $SYN_LOG" >&2
        exit 1
    fi
    if [ ! -e "$BITSTREAM" ]; then
        echo "Bitstream not found at $BITSTREAM after build, aborting" >&2
        exit 1
    fi
fi

if [ "$MODE" = flash ] || [ "$MODE" = fw ] || [ "$MODE" = both ]; then
    if [ ! -e "$BITSTREAM" ]; then
        echo "No bitstream at $BITSTREAM -- run with --build (or --both) first" >&2
        exit 1
    fi
    if [ ! -e "$FIRMWARE" ]; then
        echo "No firmware at $FIRMWARE -- run with --build (or --fw) first" >&2
        exit 1
    fi

    echo
    echo "== writing bitstream + user flash (firmware) to the internal flash =="
    # openFPGALoader exits 0 even when its CRC check fails, and prints its
    # progress only to a terminal: run it under script(1) and look for the
    # result. The write fails now and then on this board (more often with an
    # SD card inserted, probably its supply): retry a few times.
    FLASH_LOG=$(mktemp)
    ok=0
    for attempt in 1 2 3; do
        script -qec "openFPGALoader -b tangnano9k -f --user-flash $FIRMWARE $BITSTREAM" "$FLASH_LOG"
        if grep -aq "CRC check: Success" "$FLASH_LOG"; then
            ok=1
            break
        fi
        echo "== write attempt $attempt failed its CRC check, retrying ==" >&2
        sleep 2
    done
    rm -f "$FLASH_LOG"
    if [ "$ok" != 1 ]; then
        echo "Flash write failed 3 times: replug the board (removing the SD card helps) and retry" >&2
        exit 1
    fi
fi

echo
echo "Done. Open a serial terminal with:"
echo "  tio /dev/serial/by-id/usb-Silicon_Labs_CP2102* -b 115200   (J5 adapter)"
echo "  tio /dev/serial/by-id/usb-SIPEED_JTAG_Debugger_*-if01-port0 -b 115200   (BL702)"
