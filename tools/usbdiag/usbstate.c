// USB core state, sampled for 1 s, three times on each port: how often the device looked
// connected, how often the host drove the bus, the line levels, and where
// the core's microcode spent its time (pc; see the upstream ukp.s).
#include "common.h"

static uint32_t hist[1024];

int main(void) {
    settle();
    for (int round = 0; round < 6; round++) {
        uint32_t p = round & 1u;
        for (int i = 0; i < 1024; i++) hist[i] = 0;
        uint32_t n = 0, conn = 0, oe = 0, bursts = 0, last_oe = 0, err = 0, lines[4] = {0};
        for (uint32_t t0 = CLOCK_CNT; CLOCK_CNT - t0 < 1000u * MS;) {
            uint32_t d = USB_DEBUG(p), o = d >> 16 & 1u;
            n++;
            hist[d & 1023u]++;
            conn += d >> 17 & 1u;
            oe += o;
            bursts += o & ~last_oe;
            last_oe = o;
            lines[d >> 14 & 3u]++;
            err += USB_STATUS(p) >> 2 & 1u;
        }
        puts_("\nusbstate, port "); dec((int32_t)p); puts_(": "); dec((int32_t)n); puts_(" samples: connected "); dec((int32_t)(conn * 100u / n));
        puts_("%, host driving "); dec((int32_t)(oe * 100u / n)); puts_("% in "); dec((int32_t)bursts);
        puts_(" bursts, watchdog "); dec((int32_t)(err * 100u / n)); puts_("%\n  lines: SE0 ");
        dec((int32_t)(lines[0] * 100u / n)); puts_("%, D+ high "); dec((int32_t)(lines[1] * 100u / n));
        puts_("%, D- high "); dec((int32_t)(lines[2] * 100u / n)); puts_("% (low-speed idle), both ");
        dec((int32_t)(lines[3] * 100u / n)); puts_("%\n  microcode pc:");
        for (int k = 0; k < 8; k++) {
            uint32_t best = 0, bi = 0;
            for (uint32_t i = 0; i < 1024u; i++) if (hist[i] > best) { best = hist[i]; bi = i; }
            if (!best) break;
            puts_(" "); hex(bi, 3); puts_(" "); dec((int32_t)(best * 100u / n)); puts_("%");
            hist[bi] = 0;
        }
        puts_("\n");
    }
    for (;;) {}
}
