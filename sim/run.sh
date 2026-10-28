#!/usr/bin/env bash
# Simulate rtl/hyperram.sv against the behavioural PSRAM model.
#
# Usage: run.sh [TCKD_ns]   one run, writes hyperram.fst (default TCKD 3.0)
#        run.sh sweep       PASS/FAIL for a range of TCKD values
#
# View with: gtkwave hyperram.fst hyperram.gtkw
set -euo pipefail
cd "$(dirname "$0")"

PRIM=${GOWIN_HOME:-$HOME/gowin/IDE}/simlib/gw1n/prim_sim.v   # Gowin's primitives
SRCS="tb_hyperram.v psram_model.v ../rtl/hyperram.sv $PRIM"

build() { iverilog -g2012 -s tb -Ptb.TCKD="$1" -o "$2" $SRCS; }

if [ "${1-}" = sweep ]; then
    for t in $(seq 1.0 0.25 10.0); do
        build "$t" sweep.vvp
        vvp -n sweep.vvp -none | grep "TCKD="
    done
    rm -f sweep.vvp
else
    build "${1-3.0}" tb.vvp
    vvp -n tb.vvp -fst
fi
