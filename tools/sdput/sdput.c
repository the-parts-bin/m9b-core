// sdput: writes files to the SD card, received over the UART from
// sdput.py (run through tools/run.py; see sdput.py for the usage).
//
// Protocol (after "sdput ready" at 115200; after 3 s of silence it returns
// to 115200 and waits for the handshake again):
//   host -> board, 115200:  "\x1bSDPUT", then the bit period for the rest
//                           (CPU clock cycles; 39 = 921600 at 36 MHz)
//   board -> host, 115200:  "READY\n", then switches to that rate
//   host -> board:          frames as the loader's (firmware/loader.h):
//                           0xA5, block (2), length (2, <= 2048), data,
//                           checksum (4), except that the checksum also
//                           covers the block and length (a damaged block
//                           number would put data in the wrong window slot).
//                           Blocks 0..0xFFEF are file data; the others are
//                           commands.
//
// File data is windowed: the host sends up to WINDOW blocks back to back,
// numbered from the first not yet written (0 after OPEN), in any order;
// each goes into RAM, and the board answers 'k' and the block number (2
// bytes) for each good one, 'N' for a bad frame. The host resends what
// wasn't acknowledged, then sends COMMIT, which writes the window to the
// card in one go. The UART has a 16-byte FIFO and no interrupt, so the
// board can't receive while it writes the card: the host waits for
// COMMIT's answer. (Before, every 2 KB block waited for its answer: about
// 70 KB/s at 921600 baud; windowed, about 85.)
//
// Commands, answered 'K' (done) or 'E' and a line (failed), or 'N' (bad
// frame: resend):
//     0xFFF0 OPEN   path (creates missing directories, truncates the file)
//     0xFFF1 CLOSE  -> 'K', the file's checksum read back from the card (8
//                   hex digits) and '\n'
//     0xFFF2 RAWTEST write test of the card's last sector (saved, a
//                   pattern written and read back, restored): -> 'K' and a
//                   line of text
//     0xFFF3 LIST   path -> 'K', one line per entry ("f|d SIZE DATE TIME
//                   NAME", DATE and TIME as FAT's 16-bit fields), then ".\n"
//     0xFFF4 COMMIT count (2): writes the window's first count blocks
//     0xFFF5 SUM    path -> 'K', the file's checksum (8 hex digits), '\n'
//     0xFFF6 TIME   date (2), time (2), path: sets the file's time (FAT's
//                   fields; sdput.py sync compares them with the PC's)
//     0xFFF7 QUIT   -> 'K', then back to 115200 for the next handshake at
//                   once (else after 3 s of silence: a new sdput.py in
//                   between found the board deaf to the reset string)
//     0xFFF8 DELETE path: removes a file (or an empty directory)
#include <stdint.h>
#include <string.h>

#include "ff.h"
#include "sd.h"
#include "clock.h"
#include "m9b_map.h"

#define UART_DATA     (*(volatile uint32_t*)M9B_UART)
#define UART_STATUS   (*(volatile uint32_t*)(M9B_UART + 0x4u))
#define UART_DIV      (*(volatile uint32_t*)(M9B_UART + 0x8u))
#define UART_RX_VALID (1u << 8)
#define UART_OVERRUN  (1u << 2)
#define CLOCK_CNT     (*(volatile uint32_t*)(M9B_TIMING + 0xCu))   // CLOCK_HZ
#define MS            CLOCK_PER_MS
#define BLOCK_MAX     2048u
#define WINDOW        64u     // blocks: 128 KB

asm(".section .text.start\n.global _start\n_start:\n li sp, 0x900000\n"
    " la t0, __bss_start\n la t1, __bss_end\n1: bgeu t0, t1, 2f\n sw zero, 0(t0)\n addi t0, t0, 4\n j 1b\n"
    "2: call main\n3: j 3b\n");

static void put(char c) { while (UART_STATUS & 1u) {} UART_DATA = (uint8_t)c; }
static void puts_(const char *s) { while (*s) { if (*s == '\n') put('\r'); put(*s++); } }
static void raw_puts(const char *s) { while (*s) put(*s++); }
static void hex(uint32_t v, int n) { for (int s = 4 * (n - 1); s >= 0; s -= 4) put("0123456789abcdef"[(v >> s) & 15u]); }
static void dec(uint32_t v) {
    char b[12]; int i = 0;
    do { b[i++] = (char)('0' + v % 10u); v /= 10u; } while (v);
    while (i) put(b[--i]);
}

static int get_timeout(uint32_t ms) {
    uint32_t t0 = CLOCK_CNT;
    for (;;) {
        uint32_t d = UART_DATA;
        if (d & UART_RX_VALID) return (int)(d & 0xFFu);
        if (CLOCK_CNT - t0 > ms * MS) return -1;
    }
}

// The loader's checksum over n more bytes (p word-aligned): a word at a
// time, as SUM and the read-back go through whole files.
static uint32_t checksum_add(uint32_t *a_io, uint32_t *s_io, const uint8_t *p, uint32_t n) {
    uint32_t a = *a_io, s = *s_io, i = 0;
    for (; i + 4u <= n; i += 4u) {
        uint32_t w = *(const uint32_t *)(p + i);
        a += w & 0xFFu;         s += a;
        a += (w >> 8) & 0xFFu;  s += a;
        a += (w >> 16) & 0xFFu; s += a;
        a += w >> 24;           s += a;
    }
    for (; i < n; i++) { a += p[i]; s += a; }
    *a_io = a;
    *s_io = s;
    return a ^ (s << 16) ^ (s >> 16);
}

static uint8_t frame_buf[BLOCK_MAX + 1];
static uint8_t window[WINDOW * BLOCK_MAX] __attribute__((aligned(64)));
static uint16_t window_len[WINDOW];
static uint8_t window_have[WINDOW];
static uint32_t next_block;   // the window's first block

// One frame: file data straight into its window slot, a command into
// frame_buf. Nothing slow may happen between bytes once frames come back to
// back (16 bytes of FIFO last 0.17 ms at 921600 baud): the checksum is
// summed as the bytes come in, and the data isn't copied afterwards (2 KB
// into PSRAM, through the cache, took longer than that once the window
// outgrew the cache). A frame that fails its checksum after landing in a
// slot (a damaged block number could put it in another block's) takes that
// slot's block back: COMMIT then reports it missing and the host resends
// it. Returns the block number, -1 if bad, -2 if the line stayed silent.
static int get_frame(uint32_t *len_out) {
    int c;
    do {
        c = get_timeout(3000);
        if (c < 0) return -2;
    } while (c != 0xA5);
    UART_STATUS = UART_OVERRUN;   // what counts is this frame's bytes
    int b0 = get_timeout(50), b1 = get_timeout(50), l0 = get_timeout(50), l1 = get_timeout(50);
    if (b0 < 0 || b1 < 0 || l0 < 0 || l1 < 0) return -1;
    uint32_t block = (uint32_t)b0 | (uint32_t)b1 << 8, len = (uint32_t)l0 | (uint32_t)l1 << 8;
    if (len > BLOCK_MAX) return -1;
    uint8_t *dst = frame_buf;
    int slot = -1;
    if (block < 0xFFF0u && block - next_block < WINDOW) {
        slot = (int)(block - next_block);
        dst = &window[(uint32_t)slot * BLOCK_MAX];
    }
    uint32_t a = 1, s = 0;
    const int hdr[4] = {b0, b1, l0, l1};
    for (int i = 0; i < 4; i++) { a += (uint32_t)hdr[i]; s += a; }
    for (uint32_t i = 0; i < len; i++) {
        int v = get_timeout(50);
        if (v < 0) { if (slot >= 0) window_have[slot] = 0; return -1; }
        dst[i] = (uint8_t)v;
        a += (uint32_t)v;
        s += a;
    }
    uint32_t want = 0;
    int ok = 1;
    for (int i = 0; i < 4; i++) {
        int v = get_timeout(50);
        if (v < 0) { ok = 0; break; }
        want |= (uint32_t)v << (8 * i);
    }
    if (!ok || (UART_STATUS & UART_OVERRUN) || (a ^ (s << 16) ^ (s >> 16)) != want
        || (block < 0xFFF0u && slot < 0)) {   // file data outside the window
        if (slot >= 0) window_have[slot] = 0;
        return -1;
    }
    if (slot < 0) frame_buf[len] = 0;   // paths
    *len_out = len;
    return (int)block;
}

static void fail(const char *what, FRESULT r) {
    put('E'); raw_puts(what); put(' '); dec((uint32_t)r); put('\n');
}

static FATFS fs;
static FIL file;
static char open_path[256];
static int file_open;

// Creates each missing directory along path (up to its last '/').
static FRESULT make_dirs(char *path) {
    for (char *p = path + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        FRESULT r = f_mkdir(path);
        *p = '/';
        if (r != FR_OK && r != FR_EXIST) return r;
    }
    return FR_OK;
}

static uint8_t sec_orig[512] __attribute__((aligned(4))), sec_test[512] __attribute__((aligned(4))),
               sec_back[512] __attribute__((aligned(4)));
static uint32_t card_sectors;

static void raw_test(void) {
    uint32_t lba = card_sectors - 1u;
    if (!card_sectors) { raw_puts("Eno capacity\n"); return; }
    if (sd_read(lba, sec_orig, 1)) { raw_puts("Eread failed\n"); return; }
    for (uint32_t i = 0; i < 512u; i++) sec_test[i] = (uint8_t)(i * 7u + 0x5Au);
    int w1 = sd_write(lba, sec_test, 1), r1 = sd_read(lba, sec_back, 1);
    int same1 = !w1 && !r1 && memcmp(sec_test, sec_back, 512) == 0;
    int w2 = sd_write(lba, sec_orig, 1), r2 = sd_read(lba, sec_back, 1);
    int same2 = !w2 && !r2 && memcmp(sec_orig, sec_back, 512) == 0;
    put(same1 && same2 ? 'K' : 'E');
    raw_puts("sector "); dec(lba); raw_puts(": pattern write "); dec((uint32_t)w1); raw_puts(" read "); dec((uint32_t)r1);
    raw_puts(same1 ? " match" : " MISMATCH"); raw_puts(", restore write "); dec((uint32_t)w2); raw_puts(" read ");
    dec((uint32_t)r2); raw_puts(same2 ? " match\n" : " MISMATCH\n");
}

static void list_dir(const char *path) {
    static DIR dir;
    static FILINFO fi;
    FRESULT r = f_opendir(&dir, path);
    if (r != FR_OK) { fail("opendir", r); return; }
    put('K');
    while (f_readdir(&dir, &fi) == FR_OK && fi.fname[0]) {
        raw_puts(fi.fattrib & AM_DIR ? "d " : "f ");
        dec((uint32_t)fi.fsize); put(' '); dec(fi.fdate); put(' '); dec(fi.ftime); put(' ');
        raw_puts(fi.fname); put('\n');
    }
    f_closedir(&dir);
    raw_puts(".\n");
}

// The checksum of what is on the card at path; 'E' and a line on failure.
static int file_sum(const char *path, uint32_t *sum_out) {
    FRESULT r = f_open(&file, path, FA_READ);
    if (r != FR_OK) { fail("open", r); return -1; }
    uint32_t a = 1, s = 0, sum = a ^ (s << 16) ^ (s >> 16);
    UINT got;
    do {
        r = f_read(&file, window, sizeof(window), &got);
        if (r != FR_OK) { f_close(&file); fail("read", r); return -1; }
        sum = checksum_add(&a, &s, window, got);
    } while (got == sizeof(window));
    f_close(&file);
    *sum_out = sum;
    return 0;
}

static void close_and_check(void) {
    if (!file_open) { raw_puts("Eno file\n"); return; }
    file_open = 0;
    FRESULT r = f_close(&file);
    if (r != FR_OK) { fail("close", r); return; }
    uint32_t sum;   // read it back: the checksum of what is on the card
    if (file_sum(open_path, &sum) == 0) { put('K'); hex(sum, 8); put('\n'); }
}

static void commit(uint32_t count) {
    if (!file_open) { raw_puts("Eno file\n"); return; }
    if (count > WINDOW) { raw_puts("Ecount\n"); return; }
    uint32_t bytes = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (!window_have[i]) { raw_puts("Emissing block "); dec(next_block + i); put('\n'); return; }
        if (i + 1u < count && window_len[i] != BLOCK_MAX) { raw_puts("Eshort block\n"); return; }
        bytes += window_len[i];
    }
    UINT done;
    FRESULT r = f_write(&file, window, bytes, &done);
    if (r != FR_OK || done != bytes) { fail("write", r); return; }
    next_block += count;
    memset(window_have, 0, sizeof(window_have));
    put('K');
}

// Waits for the host's "\x1bSDPUT" and rate byte at 115200, answers and
// switches to that rate.
static void handshake(void) {
    static const char magic[] = "\x1bSDPUT";
    UART_DIV = UART_DIV_FOR(115200u);
    for (uint32_t m = 0;;) {
        int c = get_timeout(1000);
        if (c < 0) continue;
        m = (char)c == magic[m] ? m + 1u : (char)c == magic[0];
        if (m == sizeof(magic) - 1u) break;
    }
    int div = get_timeout(1000);
    raw_puts("READY\n");
    while (UART_STATUS & 1u) {}
    if (div >= 8) UART_DIV = (uint32_t)div;
}

int main(void) {
    for (uint32_t t0 = CLOCK_CNT; CLOCK_CNT - t0 < 200u * MS;) {}   // run.py switches back to 115200
    sd_info_t info;
    int e = sd_init(&info);
    card_sectors = e ? 0 : info.sectors;
    FRESULT r = f_mount(&fs, "", 1);
    puts_("\nsdput: card "); puts_(e ? "init failed" : "ok"); puts_(", "); dec(card_sectors / 2048u);
    puts_(" MB, mount "); dec((uint32_t)r); puts_("\nsdput ready\n");

    handshake();
    for (;;) {
        uint32_t len = 0;
        int b = get_frame(&len);
        if (b == -2) {
            // 3 s of silence: the host is gone. Back to 115200, where the
            // UART's reset string works again, and wait for the next one.
            if (file_open) { f_close(&file); file_open = 0; }
            handshake();
            continue;
        }
        if (b < 0) { put('N'); continue; }   // (no draining: frames may follow back to back)
        if (b == 0xFFF0) {                                  // OPEN
            if (file_open) { f_close(&file); file_open = 0; }
            uint32_t n = 0;
            while (frame_buf[n] && n < sizeof(open_path) - 1u) { open_path[n] = (char)frame_buf[n]; n++; }
            open_path[n] = 0;
            r = make_dirs(open_path);
            if (r == FR_OK) r = f_open(&file, open_path, FA_CREATE_ALWAYS | FA_WRITE);
            if (r != FR_OK) { fail("open", r); continue; }
            file_open = 1;
            next_block = 0;
            memset(window_have, 0, sizeof(window_have));
            put('K');
        } else if (b == 0xFFF1) {
            close_and_check();
        } else if (b == 0xFFF2) {
            raw_test();
        } else if (b == 0xFFF3) {
            list_dir((char *)frame_buf);
        } else if (b == 0xFFF4) {                           // COMMIT
            commit(len >= 2 ? (uint32_t)frame_buf[0] | (uint32_t)frame_buf[1] << 8 : 0u);
        } else if (b == 0xFFF5) {                           // SUM
            uint32_t sum;
            if (file_sum((char *)frame_buf, &sum) == 0) { put('K'); hex(sum, 8); put('\n'); }
        } else if (b == 0xFFF6) {                           // TIME
            static FILINFO fi;
            fi.fdate = (WORD)(frame_buf[0] | frame_buf[1] << 8);
            fi.ftime = (WORD)(frame_buf[2] | frame_buf[3] << 8);
            r = len > 4 ? f_utime((char *)frame_buf + 4, &fi) : FR_INVALID_NAME;
            if (r != FR_OK) fail("utime", r);
            else put('K');
        } else if (b == 0xFFF7) {                           // QUIT
            if (file_open) { f_close(&file); file_open = 0; }
            put('K');
            while (UART_STATUS & 1u) {}                     // sent before the rate changes
            handshake();
        } else if (b == 0xFFF8) {                           // DELETE
            r = f_unlink((char *)frame_buf);
            if (r != FR_OK) fail("unlink", r);
            else put('K');
        } else if (b < 0xFFF0) {                            // file data: in its window slot
            uint32_t i = (uint32_t)b - next_block;
            window_len[i] = (uint16_t)len;
            window_have[i] = 1;
            put('k'); put((char)(b & 0xFF)); put((char)(b >> 8));
        } else {
            raw_puts("Ecommand\n");
        }
    }
}
