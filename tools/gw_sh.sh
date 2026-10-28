#!/usr/bin/env bash
# Runs the Gowin IDE's Tcl shell (gw_sh) with the environment it needs on a
# current Linux distribution. The IDE is found at $GOWIN_HOME (default
# ~/gowin/IDE: the directory holding bin/gw_sh and simlib/). Built with
# Gowin EDA V1.9.11.03 Education.
#
# Usage: gw_sh.sh SCRIPT.tcl
set -euo pipefail

GOWIN_HOME=${GOWIN_HOME:-$HOME/gowin/IDE}
if [ ! -x "$GOWIN_HOME/bin/gw_sh" ]; then
    echo "no Gowin IDE at $GOWIN_HOME: set GOWIN_HOME to the directory holding bin/gw_sh" >&2
    exit 1
fi
# The IDE's own libfreetype and libz are older than the ones the system's
# Qt plugins want: load the system's first.
pre=()
for l in /usr/lib/x86_64-linux-gnu/libfreetype.so.6 /usr/lib/x86_64-linux-gnu/libz.so.1; do
    [ -e "$l" ] && pre+=("$l")
done
if [ ${#pre[@]} -gt 0 ]; then
    LD_PRELOAD=$(IFS=:; echo "${pre[*]}")
    export LD_PRELOAD
fi
export LD_LIBRARY_PATH=$GOWIN_HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
[ -d /usr/lib/x86_64-linux-gnu/qt5/plugins ] && export QT_QPA_PLATFORM_PLUGIN_PATH=/usr/lib/x86_64-linux-gnu/qt5/plugins
export QT_QPA_PLATFORM=xcb QT_XCB_GL_INTEGRATION=none
exec "$GOWIN_HOME/bin/gw_sh" "$@"
