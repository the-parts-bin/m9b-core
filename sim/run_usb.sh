#!/usr/bin/env bash
# USB host core (rtl/usb_hid_host.v, both ports) against two low-speed
# device models (usb_ls_device.v), in parallel scenarios: keyboard + mouse,
# a dead device on either port, nothing on port 0, unplug/replug and a
# port reset. Each prints, per port, the device type and when it came,
# reports ACKed by the host against those it took (ok/bad), and the longest
# keep-alive gap once configured. --old also runs the last scenario against
# two copies of the single-port core of commit 8ceeeef, for reference.
set -euo pipefail
cd "$(dirname "$0")"
out=$(mktemp -d)
build() {   # name, defines, core
    iverilog -g2012 $2 -o "$out/$1.vvp" tb_usb.v usb_ls_device.v "$3"
}
build kbd_mouse  "-DK0=1 -DK1=2" ../rtl/usb_hid_host.v
build dead_mouse "-DK0=3 -DK1=2" ../rtl/usb_hid_host.v
build mouse_dead "-DK0=2 -DK1=3" ../rtl/usb_hid_host.v
build none_kbd   "-DK0=0 -DK1=1" ../rtl/usb_hid_host.v
build replug_rst "-DK0=1 -DK1=2 -DUNPLUG -DRST" ../rtl/usb_hid_host.v
if [ "${1-}" = --old ]; then
    git show 8ceeeef:core/rtl/usb_hid_host.v | sed 's/^module usb_hid_host (/module usb_hid_host_1p (/; s/^module ukp(/module ukp_1p(/; s/^ukp ukp(/ukp_1p ukp(/' > "$out/usb_1p.v"
    build replug_rst_old "-DOLD -DK0=1 -DK1=2 -DUNPLUG -DRST" "$out/usb_1p.v"
fi
for v in "$out"/*.vvp; do vvp -n "$v" > "${v%.vvp}.log" & done
wait
for l in "$out"/*.log; do echo "== $(basename "$l" .log)"; grep -v finish "$l"; done
rm -rf "$out"
