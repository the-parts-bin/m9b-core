// SD driver test for sim/run_sd.sh, against sd_card_model.v: firmware/sd.c's
// init (High Speed switch), streamed reads across calls, non-sequential
// reads, recovery from a read left open, and every byte read; plus the
// cycles for 8 sectors at 36 and 18 MHz.
#include <stdint.h>
#include "sd.h"
#include "m9b_map.h"

#define UART_DATA   (((volatile uint32_t*)M9B_UART)[0])
#define UART_STATUS (((volatile uint32_t*)M9B_UART)[1])
#define CLOCK_CNT   (*(volatile uint32_t *)(M9B_TIMING + 0xCu))

static void putc_(char c) { while (UART_STATUS & 1u) {} UART_DATA = (uint8_t)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void puthex(uint32_t v) { for (int s = 28; s >= 0; s -= 4) putc_("0123456789abcdef"[(v >> s) & 15u]); }

static uint8_t sd_byte(uint32_t s, uint32_t i) {
    return (uint8_t)((s & 0xFFu) ^ (((s >> 8) & 0xFFu) << 1) ^ (i & 0xFFu) ^ ((i >> 8) & 1u) ^ 0x3Cu);
}
static uint8_t buf[8 * 512] __attribute__((aligned(4)));
static uint32_t bad;
static void check(uint32_t sec, uint32_t n) {
    for (uint32_t k = 0; k < n; k++)
        for (uint32_t i = 0; i < 512u; i++)
            if (buf[k * 512u + i] != sd_byte(sec + k, i)) bad++;
}
static uint32_t fails;
static uint32_t t_read;   // cycles in the last sd_read()
static void rd(uint32_t bit, uint32_t sec, uint32_t n) {
    for (uint32_t i = 0; i < n * 512u; i++) buf[i] = 0;
    uint32_t t = CLOCK_CNT;
    if (sd_read(sec, buf, n)) fails |= 1u << bit;
    t_read = CLOCK_CNT - t;
    uint32_t b0 = bad; check(sec, n); if (bad != b0) fails |= 1u << bit;
}

int main(void) {
    sd_info_t info;
    int e = sd_init(&info);
    puts_("init "); puthex((uint32_t)e); puts_(" hs "); puthex(info.high_speed);
    puts_(" sectors "); puthex(info.sectors); puts_(" div "); puthex(SPI_DIV); putc_('\n');

    rd(0, 100, 4);      // opens a stream
    rd(1, 104, 2);      // continues it
    rd(2, 50, 1);       // jumps: CMD12, new CMD18
    rd(3, 51, 3);       // continues
    sd_stop();
    rd(4, 7, 1);        // fresh after a stop

    // Timing: 8 sectors in one call (fresh stream), at 36 and at 18 MHz.
    uint32_t c36, c18;
    sd_stop(); rd(5, 200, 8); c36 = t_read;
    sd_stop(); uint32_t div = SPI_DIV; SPI_DIV = 0;
    rd(6, 300, 8); c18 = t_read;
    sd_stop(); SPI_DIV = div;

    // A program that starts while a read is still open (no sd_stop()):
    // sd_init() has to recover the card.
    rd(7, 400, 1);
    e = sd_init(&info);
    if (e) fails |= 1u << 8;
    rd(9, 401, 2);
    sd_stop();

    puts_("sd fails "); puthex(fails); puts_(" bad bytes "); puthex(bad);
    puts_(" 8 sectors: 36MHz "); puthex(c36); puts_(" 18MHz "); puthex(c18);
    puts_("\ndone\n");
    for (;;) {}
}
