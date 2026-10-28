#!/usr/bin/env bash
# BSRAM byte-enable test (see bsram_be.v): build, load into the FPGA's SRAM
# (not the flash: a power cycle brings the normal design back), and show the
# UART for a few passes.
#   ./build.sh [MHZ]          build at 27 (default), 36 or 72 MHz, load, listen 20 s
#   ./build.sh --load         load the existing bitstream + listen
set -euo pipefail
cd "$(dirname "$0")"
if [ "${1-}" != "--load" ]; then
    MHZ=${1:-27}
    case "$MHZ" in 27|36|72) ;; *) echo "clock: 27, 36 or 72" >&2; exit 1 ;; esac
    echo "\`define CLK_MHZ $MHZ" > clk_sel.vh
    ../../tools/gw_sh.sh build.tcl > build.log 2>&1 || true
    if grep -qE '^ERROR' build.log || [ ! -e impl/pnr/bsram_be.fs ]; then
        grep -E '^ERROR' build.log | head; echo "build failed, see build.log" >&2; exit 1
    fi
    grep -E 'BSRAM  ' impl/pnr/bsram_be.rpt.txt
    python3 -c "
import re,html
t=open('impl/pnr/bsram_be_tr_content.html').read()
i=t.find('Max Frequency Summary')
s=re.sub(r'<[^>]+>',' ',t[i:i+2000]); s=html.unescape(s); s=re.sub(r'\\s+',' ',s)
print(re.findall(r'(clk\\w*) (\\d+\\.\\d+)\\(MHz\\) (\\d+\\.\\d+)\\(MHz\\)',s))"
fi
script -qec "openFPGALoader -b tangnano9k impl/pnr/bsram_be.fs" /dev/null | tr '\r' '\n' | grep -aE 'Done|rror|unable' | tail -1
python3 - <<'PY'
import serial, glob, time, sys
port = (glob.glob('/dev/serial/by-id/usb-Silicon_Labs_CP2102*') or glob.glob('/dev/serial/by-id/usb-SIPEED*if01*'))[0]
s = serial.Serial(port, 115200, timeout=0.2)
t = time.time()
while time.time() - t < 20:
    d = s.read(4096)
    if d: sys.stdout.write(d.decode('latin1').replace('\r', '')); sys.stdout.flush()
PY
