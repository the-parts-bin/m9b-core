// Bus capture: resets the USB core of port PORT (0; for the second port
// build with `make clean; make PORT=1`), then records every change of {host
// driving, D-, D+} for 600 ms (about 1.4 samples per us: enough to see the
// bus reset, keep-alives, packets and whether the device answers, not to
// decode bits). Prints states lasting >= 20 us, and shorter ones merged
// into bursts ("free" = the host isn't driving: the device or the pulls).
#include "common.h"

#define N 8000
static uint32_t ts[N], st[N];

static const char *const names[8] = {
    "SE0 (free)", "D+ high (free)", "D- high: low-speed idle (free)", "both high (free)",
    "host SE0", "host D+ high", "host D- high", "host both high"};

int main(void) {
    settle();
    USB_STATUS(PORT) = 1;
    for (uint32_t t0 = CLOCK_CNT; CLOCK_CNT - t0 < 5u * MS;) {}
    uint32_t n = 0, last = 0xFFu, loops = 0, t0 = CLOCK_CNT;
    USB_STATUS(PORT) = 0;
    const uint32_t span = 600u * MS;
    while (CLOCK_CNT - t0 < span) {
        uint32_t d = USB_DEBUG(PORT), s = d >> 14 & 7u;
        loops++;
        if (s != last && n < N) { ts[n] = CLOCK_CNT - t0; st[n] = s | (d & 0x3FFFu) << 4; n++; last = s; }
    }
    puts_("\nusbbus, port "); dec(PORT); puts_(": "); dec((int32_t)n); puts_(" changes, "); dec((int32_t)(loops / 600u)); puts_(" samples/ms\n");
    for (uint32_t i = 0, lines = 0; i < n && lines < 150; lines++) {
        uint32_t end = i + 1 < n ? ts[i + 1] : span;
        if (end - ts[i] >= 20u * CLOCK_PER_US) {
            dec((int32_t)(ts[i] / CLOCK_PER_US)); puts_(" us: "); puts_(names[st[i] & 7u]); puts_(" for ");
            dec((int32_t)((end - ts[i]) / CLOCK_PER_US)); puts_(" us (pc "); hex(st[i] >> 4, 3); puts_(")\n");
            i++;
            continue;
        }
        uint32_t j = i, host = 0;
        while (j < n && (j + 1 < n ? ts[j + 1] : span) - ts[j] < 20u * CLOCK_PER_US) { host += st[j] >> 2 & 1u; j++; }
        dec((int32_t)(ts[i] / CLOCK_PER_US)); puts_(" us: burst of "); dec((int32_t)(j - i)); puts_(" changes (");
        dec((int32_t)host); puts_(" host-driven, "); dec((int32_t)(j - i - host)); puts_(" free), pc ");
        hex(st[i] >> 4, 3); puts_(".."); hex(st[j - 1] >> 4, 3); puts_("\n");
        i = j;
    }
    for (;;) {}
}
