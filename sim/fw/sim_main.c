// Simulation-only test program for sim/tb_soc.v (a short frame: 720 x 6
// visible lines out of 10). Exercises the cached PSRAM window (line refills
// and write-backs through psram_bridge), running code from PSRAM with
// cbo.clean + fence.i, and the video engine: a one-pixel white frame drawn
// from two lines in PSRAM through the line table, with the vertical
// blanking interrupt. Little UART output (UART time is slow to simulate).
#include <stdint.h>
#include "m9b_map.h"

#define UART_DATA   (((volatile uint32_t*)M9B_UART)[0])
#define UART_STATUS (((volatile uint32_t*)M9B_UART)[1])
#define PSRAM       ((volatile uint32_t*)M9B_PSRAM_BASE)
#define VRAM_TABLE  (((volatile uint32_t*)M9B_VRAM) + 640)
#define VIDEO_CTRL  (((volatile uint32_t*)M9B_CTRL)[0])
#define IRQ_PENDING (((volatile uint32_t*)M9B_CTRL)[1])
#define IRQ_ENABLE  (((volatile uint32_t*)M9B_CTRL)[2])
#define ACTIVE_H    6u

static void putc_(char c) {
    while (UART_STATUS & 1u) {
    }
    UART_DATA = (uint8_t)c;
}

static void puts_(const char *s) {
    while (*s) putc_(*s++);
}

static void puthex(uint32_t v) {
    for (int s = 28; s >= 0; s -= 4) putc_("0123456789abcdef"[(v >> s) & 15u]);
}

static uint32_t pattern(uint32_t i) {
    return i * 0x9E3779B1u + 0x7F4A7C15u;
}

static void cache_clean(uint32_t addr, uint32_t bytes) {
    for (uint32_t a = addr & ~63u; a < addr + bytes; a += 64u)
        asm volatile("cbo.clean (%0)" :: "r"(a) : "memory");
}

static volatile uint32_t vblanks;

__attribute__((interrupt("machine")))
static void trap_handler(void) {
    uint32_t p = IRQ_PENDING;
    IRQ_PENDING = p;
    if (p & 1u) vblanks++;
}

#define SPI_DATA (*(volatile uint32_t *)M9B_SPI)
#define SPI_CTRL (*(volatile uint32_t *)(M9B_SPI + 0x4u))
#define SPI_DIV  (*(volatile uint32_t *)(M9B_SPI + 0x8u))
#define SPI_STREAM (*(volatile uint32_t *)(M9B_SPI + 0xCu))
#define SPI_LAST   (*(volatile uint32_t *)(M9B_SPI + 0x1Cu))
static uint32_t spi_xfer(uint32_t b) {
    SPI_DATA = b;
    while (SPI_CTRL & 0x100u) {
    }
    return SPI_DATA;
}

int main(void) {
    puts_("boot\n");

    // Byte-lane test: byte stores into a cached buffer, read back.
    {
        volatile uint8_t *b8 = (volatile uint8_t *)(M9B_PSRAM_BASE + 0x10000u);
        uint32_t lanes = 0;
        for (uint32_t i = 0; i < 512u; i++) b8[i] = (uint8_t)(i * 13u + 1u);
        for (uint32_t i = 0; i < 512u; i++)
            if (b8[i] != (uint8_t)(i * 13u + 1u)) lanes |= 1u << (i & 7u);
        puts_("lane test: failing lanes ");
        puthex(lanes);
        putc_('\n');
    }

    // SPI flash (spi_flash_model.v): JEDEC ID, then 4 bytes from 0x123456.
    SPI_DIV = 0u;
    SPI_CTRL = 0x11u;   // drive the pins, select the flash
    spi_xfer(0x9Fu);
    uint32_t id = spi_xfer(0) << 16;
    id |= spi_xfer(0) << 8;
    id |= spi_xfer(0);
    SPI_CTRL = 0x10u;
    SPI_CTRL = 0x11u;   // drive the pins, select the flash
    spi_xfer(0x03u); spi_xfer(0x12u); spi_xfer(0x34u); spi_xfer(0x56u);
    uint32_t d = 0;
    for (int k = 0; k < 4; k++) d = (d << 8) | spi_xfer(0);
    SPI_CTRL = 0u;      // release the pins
    puts_("spi flash id ");
    puthex(id);
    puts_(" data ");
    puthex(d);
    putc_('\n');

    // The same through SPI_STREAM: 16 bytes from 0x123456 as 4 words (a
    // write starts the first, SPI_LAST ends without starting a fifth).
    SPI_CTRL = 0x11u;
    spi_xfer(0x03u); spi_xfer(0x12u); spi_xfer(0x34u); spi_xfer(0x56u);
    SPI_STREAM = 0;
    uint32_t w[4];
    for (int k = 0; k < 3; k++) w[k] = SPI_STREAM;
    w[3] = SPI_LAST;
    SPI_CTRL = 0u;
    uint32_t bad = 0;
    for (uint32_t i = 0; i < 16u; i++) {
        uint32_t a = 0x123456u + i;
        uint32_t want = ((a & 0xFFu) ^ ((a >> 8) & 0xFFu) ^ 0x5Au) & 0xFFu;
        if (((w[i / 4u] >> (8u * (i % 4u))) & 0xFFu) != want) bad |= 1u << i;
    }
    puts_("spi stream ");
    puthex(w[0]);
    puts_(" bad bytes ");
    puthex(bad);
    putc_('\n');

    // 12 KB through the 8 KB data L1: every line gets written back and
    // refilled at least once. This program's data and stack sit in the top
    // 128 KB of PSRAM (firmware/link.ld); psram_model.v only has 256 KB
    // (addresses wrap), so they land at 128 KB .. 256 KB and the tests use
    // 64 KB .. 104 KB.
    const uint32_t words = 3072;
    volatile uint32_t *buf = PSRAM + 0x4000;   // PSRAM + 0x10000
    for (uint32_t i = 0; i < words; i++) buf[i] = pattern(i);
    uint32_t errors = 0;
    for (uint32_t i = 0; i < words; i++)
        if (buf[i] != pattern(i)) errors++;
    puts_("psram rw: ");
    puts_(errors ? "FAIL " : "PASS ");
    puthex(errors);
    putc_('\n');

    // Code in PSRAM: x * x + 1.
    volatile uint32_t *code = PSRAM + 0x5000;   // PSRAM + 0x14000
    code[0] = 0x02a50533u;   // mul  a0, a0, a0
    code[1] = 0x00150513u;   // addi a0, a0, 1
    code[2] = 0x00008067u;   // ret
    cache_clean(M9B_PSRAM_BASE + 0x14000u, 12u);
    asm volatile("fence.i" ::: "memory");
    int r = ((int (*)(int))(uintptr_t)code)(7);
    puts_("psram exec: ");
    puts_(r == 50 ? "PASS " : "FAIL ");
    puthex((uint32_t)r);
    putc_('\n');

    // Miss trace (tb_soc.v logs each step for lines at PSRAM 0x28000 ..
    // 0x283FF): read 32 KB at 0x10000, so the 16 KB data L1 holds clean
    // lines of 0x14000 .. 0x17FFF, then
    //   4 loads at 0x28000.. (clean victims 0x14000..)
    //   4 loads at 0x28100.. after dirtying 0x14100.. (dirty victims)
    //   4 stores at 0x28200.. after dirtying 0x14200.. (dirty victims)
    // each timed with CLOCK_CNT, less the same with a hit.
#define CLOCK_CNT (*(volatile uint32_t *)(M9B_TIMING + 0xCu))
    {
        volatile uint32_t *p = PSRAM;
        uint32_t s = 0, dt[13];
        for (uint32_t a = 0x10000u; a < 0x18000u; a += 64u) s += p[a / 4u];
        for (uint32_t k = 0; k < 4u; k++) {
            uint32_t t0 = CLOCK_CNT; s += p[(0x28000u + 64u * k) / 4u]; dt[k] = CLOCK_CNT - t0;
        }
        for (uint32_t k = 0; k < 4u; k++) p[(0x14100u + 64u * k) / 4u] = k;
        for (uint32_t k = 0; k < 4u; k++) {
            uint32_t t0 = CLOCK_CNT; s += p[(0x28100u + 64u * k) / 4u]; dt[4u + k] = CLOCK_CNT - t0;
        }
        for (uint32_t k = 0; k < 4u; k++) p[(0x14200u + 64u * k) / 4u] = k;
        for (uint32_t k = 0; k < 4u; k++) {
            uint32_t t0 = CLOCK_CNT; p[(0x28200u + 64u * k) / 4u] = s; dt[8u + k] = CLOCK_CNT - t0;
        }
        { uint32_t t0 = CLOCK_CNT; s += p[0x28000u / 4u]; dt[12] = CLOCK_CNT - t0; }
        puts_("miss cycles (clean ld x4, dirty ld x4, dirty st x4, hit):");
        for (uint32_t k = 0; k < 13u; k++) { putc_(' '); puthex(dt[k]); }
        putc_('\n');
    }

    // Video: white line at PSRAM 0x18000, frame line (white at x = 0 and
    // 719) at 0x18600, both 16 bpp.
    volatile uint16_t *white = (volatile uint16_t *)(M9B_PSRAM_BASE + 0x18000u);
    volatile uint16_t *frame = (volatile uint16_t *)(M9B_PSRAM_BASE + 0x18600u);
    for (uint32_t x = 0; x < 720u; x++) {
        white[x] = 0xFFFFu;
        frame[x] = (x == 0u || x == 719u) ? 0xFFFFu : 0u;
    }
    cache_clean(M9B_PSRAM_BASE + 0x18000u, 3072u);
    for (uint32_t y = 0; y < ACTIVE_H; y++)
        VRAM_TABLE[y] = (1u << 22) | ((y == 0u || y == ACTIVE_H - 1u) ? 0x180u : 0x186u);

    asm volatile("csrw mtvec, %0" :: "r"(&trap_handler));
    IRQ_PENDING = 7u;
    IRQ_ENABLE = 1u;
    asm volatile("csrs mie, %0" :: "r"(1u << 11));
    asm volatile("csrs mstatus, %0" :: "r"(1u << 3));
    VIDEO_CTRL = 1u;

    while (vblanks < 4u) {
    }
    puts_("vblanks: ");
    puthex(vblanks);
    putc_('\n');
    puts_("done\n");
    for (;;) {
    }
}
