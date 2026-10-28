// Prints each report on either port: keys (modifiers, up to four key
// codes) or mouse buttons and motion with the hardware's running sums
// (MOUSE_POS); also status changes (device type, watchdog). Stops printing
// reports after 200.
#include "common.h"

int main(void) {
    settle();
    puts_("\nusbreport: status changes and reports, both ports\n");
    uint32_t count[2], last[2] = {0xFFFFFFFFu, 0xFFFFFFFFu}, n = 0, t0 = CLOCK_CNT;
    for (uint32_t p = 0; p < 2u; p++) count[p] = USB_STATUS(p) >> 8 & 0xFFu;
    for (uint32_t p = 0;; p ^= 1u) {
        uint32_t st = USB_STATUS(p), c = st >> 8 & 0xFFu;
        if ((st & 7u) != (last[p] & 7u)) {
            dec((int32_t)((CLOCK_CNT - t0) / MS)); puts_(" ms: port "); dec((int32_t)p);
            puts_(" device type "); dec((int32_t)(st & 3u));
            puts_(st & 4u ? " (watchdog: no answer, or no device)\n" : "\n");
        }
        last[p] = st;
        if (c == count[p]) continue;
        count[p] = c;
        if (n++ >= 200u) continue;
        dec((int32_t)((CLOCK_CNT - t0) / MS)); puts_(" ms: port "); dec((int32_t)p); puts_(" ");
        if ((st & 3u) == 2u) {
            uint32_t m = USB_MOUSE(p), pos = USB_MOUSE_POS(p);
            int32_t dx = (int8_t)(m >> 8), dy = (int8_t)(m >> 16);
            puts_("mouse buttons "); hex(m & 0xFFu, 2); puts_(" dx "); dec(dx); puts_(" dy "); dec(dy);
            puts_(" (pos "); dec((int16_t)pos); puts_(", "); dec((int16_t)(pos >> 16)); puts_(")\n");
        } else {
            uint32_t k = USB_KEYS(p);
            puts_("keys: modifiers "); hex(k & 0xFFu, 2); puts_(" codes "); hex(k >> 8 & 0xFFu, 2); putc_(' ');
            hex(k >> 16 & 0xFFu, 2); putc_(' '); hex(k >> 24, 2); putc_(' '); hex(USB_KEYS2(p) & 0xFFu, 2); puts_("\n");
        }
    }
}
