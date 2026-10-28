// Serial loader: receives a program over the UART into memory and runs it
// (see loader.h for the protocol, and tools/run.py).
#include "loader.h"
#include "clock.h"
#include "sd.h"
#include "m9b_map.h"

#define UART_DATA     (*(volatile uint32_t*)M9B_UART)
#define UART_STATUS   (*(volatile uint32_t*)(M9B_UART + 0x4u))
#define UART_DIV      (*(volatile uint32_t*)(M9B_UART + 0x8u))
#define UART_TX_BUSY  (1u << 0)
#define UART_RX_VALID (1u << 8)
#define UART_OVERRUN  (1u << 2)
#define CLOCK_CNT     (*(volatile uint32_t*)(M9B_TIMING + 0xCu))   // CLOCK_HZ
#define VIDEO_CTRL    (*(volatile uint32_t*)M9B_CTRL)
#define IRQ_ENABLE    (*(volatile uint32_t*)(M9B_CTRL + 0x8u))
#define AUDIO_CTRL    (*(volatile uint32_t*)(M9B_CTRL + 0xCu))

#define DIV_SLOW  UART_DIV_FOR(115200u)
#define MS        CLOCK_PER_MS      // clock_cnt ticks per millisecond
#define BLOCK_MAX 2048u

static const char magic[] = "\x1bM9BLOAD";   // host -> board, at 115200
static uint32_t matched;

static void put(char c) {
    while (UART_STATUS & UART_TX_BUSY) {
    }
    UART_DATA = (uint8_t)c;
}

static void puts_(const char *s) {
    while (*s) put(*s++);
}

static void puthex(uint32_t v) {
    for (int s = 28; s >= 0; s -= 4) put("0123456789abcdef"[(v >> s) & 15u]);
}

static void wait_tx_done(void) {
    while (UART_STATUS & UART_TX_BUSY) {
    }
}

// Next received byte, or -1 after `ms` milliseconds without one.
static int get_timeout(uint32_t ms) {
    uint32_t t0 = CLOCK_CNT;
    for (;;) {
        uint32_t d = UART_DATA;
        if (d & UART_RX_VALID) return (int)(d & 0xFFu);
        if (CLOCK_CNT - t0 > ms * MS) return -1;
    }
}

// Waits until the line has been quiet for 5 ms, dropping what comes in.
static void drain(void) {
    while (get_timeout(5) >= 0) {
    }
    UART_STATUS = UART_OVERRUN;
}

int loader_feed(int c) {
    if ((char)c == magic[matched]) {
        if (++matched == sizeof(magic) - 1u) {
            matched = 0;
            return 1;
        }
    } else {
        matched = (char)c == magic[0];
    }
    return 0;
}

// Why the last frame was bad (sent after 'N' for tools/run.py to print).
static uint32_t why, why_pos, why_got, why_want;

// Receives one frame: 0xA5, block (2 bytes), length (2), data, checksum (4).
// Returns the block number (the data goes to base + block * BLOCK_MAX, if
// it ends within size bytes, or to hdr for block 0xFFFE), -1 if the frame
// was bad, -2 if nothing came.
static int get_frame(uint8_t *base, uint32_t size, uint8_t *hdr, uint32_t *len_out) {
    int c;
    do {                                     // skip to the sync byte
        c = get_timeout(3000);
        if (c < 0) return -2;
    } while (c != 0xA5);
    int b0 = get_timeout(50), b1 = get_timeout(50), l0 = get_timeout(50), l1 = get_timeout(50);
    if (b0 < 0 || b1 < 0 || l0 < 0 || l1 < 0) { why = 1; return -1; }
    uint32_t block = (uint32_t)b0 | (uint32_t)b1 << 8, len = (uint32_t)l0 | (uint32_t)l1 << 8;
    if (len > BLOCK_MAX) { why = 2; why_pos = len; return -1; }
    // (Checked before a byte is stored: a garbled block number must not
    // write over the firmware, above the program.)
    if (block != 0xFFFEu && (block >= size / BLOCK_MAX + 1u || block * BLOCK_MAX + len > size)) {
        why = 7;
        why_pos = block;
        return -1;
    }
    volatile uint8_t *p = block == 0xFFFEu ? hdr : base + block * BLOCK_MAX;
    uint32_t a = 1, s = 0;
    for (uint32_t i = 0; i < len; i++) {
        int v = get_timeout(50);
        if (v < 0) { why = 3; why_pos = i; return -1; }
        p[i] = (uint8_t)v;
        a += (uint32_t)v;
        s += a;
    }
    uint32_t want = 0;
    for (int i = 0; i < 4; i++) {
        int v = get_timeout(50);
        if (v < 0) { why = 4; return -1; }
        want |= (uint32_t)v << (8 * i);
    }
    uint32_t sum = a ^ (s << 16) ^ (s >> 16);
    if (UART_STATUS & UART_OVERRUN) { why = 5; return -1; }
    if (sum != want) { why = 6; why_pos = block; why_got = sum; why_want = want; return -1; }
    *len_out = len;
    return (int)block;
}

void loader_run(void) {
    // The byte after the magic string: the bit period for the transfer, in
    // CPU clock cycles. Answer at 115200, then switch once "READY" is out.
    int div = get_timeout(1000);
    if (div < 8) {
        puts_("\r\nloader: bad rate\r\n");
        return;
    }
    // No interrupts during the transfer: the audio refill alone takes
    // ~0.5 ms, longer than the 16-byte receive FIFO lasts.
    uint32_t mstatus;
    asm volatile("csrrc %0, mstatus, %1" : "=r"(mstatus) : "r"(1u << 3));
    // Video off: the boot screen (+7.5 MB) is clear of the program, but the
    // display DMA needn't compete with the upload.
    VIDEO_CTRL = 0;
    puts_("\r\nREADY\n");
    wait_tx_done();
    UART_DIV = (uint32_t)div;

    // Header frame (block 0xFFFE: load address, length), then data blocks
    // 0, 1, ..., each answered with 'K' or (after draining the line) 'N'.
    uint32_t hdr[2] = {0, 0}, addr = 0, total = 0, next = 0, got = 0, retries = 0;
    int have_hdr = 0;
    for (;;) {
        uint32_t len = 0;
        int b = get_frame((uint8_t *)(uintptr_t)addr, total, (uint8_t *)hdr, &len);
        if (b == -2) break;                                  // host gone
        if (b < 0) {
            drain();
            put('N');
            // why: 1 header timeout, 2 bad length, 3 data timeout at pos,
            // 4 checksum timeout, 5 overrun, 6 checksum (block, got, want),
            // 7 block outside the header's length (block)
            puthex(why); put(' '); puthex(why_pos); put(' '); puthex(why_got); put(' '); puthex(why_want); put('\n');
            retries++;
            continue;
        }
        if (b == 0xFFFE) {
            if (len != 8) { drain(); put('N'); retries++; continue; }
            if (hdr[0] < LOAD_BASE || hdr[0] >= LOAD_LIMIT || hdr[1] > LOAD_LIMIT - hdr[0]) {
                put('K');
                wait_tx_done();
                UART_DIV = DIV_SLOW;
                puts_("\r\nloader: doesn't fit (");
                puthex(hdr[0]);
                put(' ');
                puthex(hdr[1]);
                puts_(")\r\n");
                asm volatile("csrs mstatus, %0" :: "r"(mstatus & (1u << 3)));
                return;
            }
            addr = hdr[0];
            total = hdr[1];
            have_hdr = 1;
            put('K');
            if (total == 0) break;
            continue;
        }
        if (!have_hdr) { drain(); put('N'); retries++; continue; }
        if ((uint32_t)b == next) {
            next++;
            got += len;
        }
        put('K');                // also for a repeat (our 'K' got lost)
        if (got >= total) break;
    }
    int ok = have_hdr && got == total && total != 0;
    puts_(ok ? "OK " : "BAD ");
    puthex(got);
    put(' ');
    puthex(retries);
    puts_("\n");
    wait_tx_done();
    for (uint32_t t0 = CLOCK_CNT; CLOCK_CNT - t0 < 20u * MS;) {   // host reads, switches back
    }
    UART_DIV = DIV_SLOW;
    if (!ok) {
        puts_("\r\nloader: transfer failed, not starting\r\n");
        asm volatile("csrs mstatus, %0" :: "r"(mstatus & (1u << 3)));
        return;
    }

    loader_start(addr, total);
}

void loader_start(uint32_t addr, uint32_t len) {
    // Quiesce: no interrupts, audio or video DMA, no SD read left running
    // (the program initializes the card itself); code must reach PSRAM
    // (clean the data cache) and the fetch cache must not hold stale lines.
    sd_stop();
    asm volatile("csrc mstatus, %0" :: "r"(1u << 3));
    IRQ_ENABLE = 0;
    AUDIO_CTRL = 0;
    VIDEO_CTRL = 0;
    for (uint32_t x = addr & ~63u; x < addr + len; x += 64u)
        asm volatile("cbo.clean (%0)" :: "r"(x) : "memory");
    asm volatile("fence.i" ::: "memory");
    ((void (*)(void))(uintptr_t)addr)();
}
