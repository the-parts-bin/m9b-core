// Shared by the USB diagnostics: registers (see ../../README.md, USB host),
// the UART and the entry point. Programs run from PSRAM, loaded by
// tools/run.py (no C library, no interrupts).
#include <stdint.h>

#define UART_DATA   (*(volatile uint32_t*)M9B_UART)
#define UART_STATUS (*(volatile uint32_t*)(M9B_UART + 0x4u))
#include "../../firmware/clock.h"
#include "m9b_map.h"

#define CLOCK_CNT   (*(volatile uint32_t*)(M9B_TIMING + 0xCu))   // CLOCK_HZ
// Port p (0: pins 25/26, 1: pins 27/28) at M9B_USB + 0x20 p.
#define USB_REG(p, o) (*(volatile uint32_t*)(M9B_USB + 0x20u * (p) + (o)))
#define USB_STATUS(p)    USB_REG(p, 0x00u)   // write bit 0: hold the core in reset
#define USB_KEYS(p)      USB_REG(p, 0x04u)
#define USB_KEYS2(p)     USB_REG(p, 0x08u)
#define USB_MOUSE(p)     USB_REG(p, 0x0Cu)
#define USB_DEBUG(p)     USB_REG(p, 0x10u)   // {connected, oe, dm, dp, pc[13:0]}
#define USB_MOUSE_POS(p) USB_REG(p, 0x14u)   // {y, x} running sums
#ifndef PORT
#define PORT 0   // usbbus: the port to capture
#endif
#define MS          CLOCK_PER_MS

asm(".section .text.start\n.global _start\n_start:\n li sp, 0x900000\n"
    " la t0, __bss_start\n la t1, __bss_end\n1: bgeu t0, t1, 2f\n sw zero, 0(t0)\n addi t0, t0, 4\n j 1b\n"
    "2: call main\n3: j 3b\n");

// run.py switches the host back to 115200 after the upload; output in the
// first few ms after the jump is lost, so programs wait first.
static void settle(void) { for (uint32_t t0 = CLOCK_CNT; CLOCK_CNT - t0 < 200u * MS;) {} }

static void putc_(char c) { while (UART_STATUS & 1u) {} UART_DATA = (uint8_t)c; }
static void puts_(const char *s) { while (*s) { if (*s == '\n') putc_('\r'); putc_(*s++); } }
static void hex(uint32_t v, int n) { for (int s = 4 * (n - 1); s >= 0; s -= 4) putc_("0123456789abcdef"[(v >> s) & 15u]); }
static void dec(int32_t v) {
    char b[12]; int i = 0; uint32_t u = v < 0 ? (uint32_t)-v : (uint32_t)v;
    if (v < 0) putc_('-');
    do { b[i++] = (char)('0' + u % 10u); u /= 10u; } while (u);
    while (i) putc_(b[--i]);
}
