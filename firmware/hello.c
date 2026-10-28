#include <stdint.h>

// Memory map: m9b_map.h. This program runs from the user flash; its data
// and stack are in the top 128 KB of PSRAM (link.ld).

#define UART_BASE     ((volatile uint32_t*)M9B_UART)
#define UART_DATA     (UART_BASE[0])
#define UART_STATUS   (UART_BASE[1])
#define UART_TX_BUSY  (1u << 0)
#define UART_RX_VALID (1u << 8)

// Cached PSRAM window: the CPU's L1 caches refill and write back 64-byte
// lines through psram_bridge. The video/audio engine reads PSRAM directly,
// so data it will read has to be written back first (cache_clean below).
#define PSRAM        ((volatile uint32_t*)M9B_PSRAM_BASE)
#define PSRAM_BASE   M9B_PSRAM_BASE

// Video RAM (see rtl/vram.v): font at word 0 (128 chars x 16 rows, byte
// char * 16 + row), palette at word 512 (256 x RGB565), line table at word
// 640 (480 entries, see rtl/video_engine.v).
#define VRAM         ((volatile uint32_t*)M9B_VRAM)
#define VRAM_TABLE   (VRAM + 640)

#define LINE_BLANK   (0u << 22)
#define LINE_16BPP   (1u << 22)
#define LINE_8BPP    (2u << 22)
#define LINE_TEXT    (3u << 22)
#define LINE_ENTRY(mode, psram_offset, scroll, font_row) \
    ((mode) | ((uint32_t)(font_row) << 24) | ((uint32_t)(scroll) << 15) | ((psram_offset) >> 8))

typedef struct CTRL_IO {
  volatile uint32_t video_ctrl;   // bit 0: video enable
  volatile uint32_t irq_pending;  // bit 0 vblank, 1 audio A done, 2 audio B done; write 1s to clear
  volatile uint32_t irq_enable;
  volatile uint32_t audio_ctrl;   // bit 0: audio enable
  volatile uint32_t audio_ptr[2]; // PSRAM offsets (256-byte aligned) of 1 KB of samples;
                                  // writing one DMAs it into that half
} CTRL_IO;
#define ctrl ((CTRL_IO*)M9B_CTRL)
#define IRQ_VBLANK   (1u << 0)
#define IRQ_AUDIO_A  (1u << 1)
#define IRQ_AUDIO_B  (1u << 2)

typedef struct VIDEO_IO {
  volatile uint32_t x_cnt;
  volatile uint32_t y_cnt;
  volatile uint32_t frame_cnt;
  volatile uint32_t clock_cnt;    // CLOCK_HZ (the CPU clock)
} VIDEO_IO;
#define video ((VIDEO_IO*)M9B_TIMING)

#include "sd.h"          // SPI master registers, spi_xfer(), SD card
#include "fatfs/ff.h"
#include "loader.h"         // serial loader (tools/run.py)
#include "boot.h"           // boot screen and program browser
#include "clock.h"          // CLOCK_HZ
#include "assets.h"         // UI_* colours
#include "m9b_map.h"


static void uart_putc(char c) {
    while (UART_STATUS & UART_TX_BUSY) {
    }
    UART_DATA = (uint32_t)(uint8_t)c;
}

static void uart_puts(const char *s) {
    while (*s) {
        if (*s == '\n') uart_putc('\r');
        uart_putc(*s++);
    }
}

static void uart_puthex32(uint32_t v) {
    static const char digits[] = "0123456789ABCDEF";
    for (int shift = 28; shift >= 0; shift -= 4) uart_putc(digits[(v >> shift) & 0xF]);
}

static void uart_putdec(uint32_t v) {
    char buf[10];
    int n = 0;
    do {
        buf[n++] = (char)('0' + v % 10u);
        v /= 10u;
    } while (v);
    while (n) uart_putc(buf[--n]);
}

// Writes back every data L1 line of [addr, addr + bytes) to PSRAM.
static void cache_clean(uint32_t addr, uint32_t bytes) {
    for (uint32_t a = addr & ~63u; a < addr + bytes; a += 64u)
        asm volatile("cbo.clean (%0)" :: "r"(a) : "memory");
}

static void print_rate(const char *label, uint32_t bytes, uint32_t cycles, uint32_t row) {
    char t[24];
    fmt_rate(t, bytes, cycles);
    boot_test(row, t, UI_TEXT);
    uint32_t us = cycles / CLOCK_PER_US;               // ticks -> us
    if (!us) us = 1u;
    uint32_t mb10 = (bytes / us) * 10u + (bytes % us) * 10u / us;   // bytes/us = MB/s
    uart_puts(label);
    uart_putdec(us);
    uart_puts(" us, ");
    uart_putdec(mb10 / 10u);
    uart_putc('.');
    uart_putdec(mb10 % 10u);
    uart_puts(" MB/s\n");
}

static uint32_t pattern(uint32_t word_addr) {
    return word_addr * 0x9E3779B1u + 0x7F4A7C15u;
}

// -------------------------------------------------------------------------
// PSRAM through the caches
// -------------------------------------------------------------------------
#define PSRAM_TEST_WORDS ((1u << 20) / 4u)   // 1 MB at PSRAM offset 6 MB

static void psram_cached_test(void) {
    volatile uint32_t *p = PSRAM + (6u << 20) / 4u;
    uart_puts("cached PSRAM test, 1 MB through the L1 caches: ");
    uint32_t t0 = video->clock_cnt;
    for (uint32_t i = 0; i < PSRAM_TEST_WORDS; i++) p[i] = pattern(i) ^ 0x5A5A5A5Au;
    uint32_t errors = 0;
    for (uint32_t i = 0; i < PSRAM_TEST_WORDS; i++) {
        uint32_t got = p[i];
        uint32_t want = pattern(i) ^ 0x5A5A5A5Au;
        if (got != want) {
            if (errors < 4u) {
                uart_puts("\n  mismatch at 0x");
                uart_puthex32((uint32_t)(uintptr_t)&p[i]);
                uart_puts(": got 0x");
                uart_puthex32(got);
                uart_puts(" want 0x");
                uart_puthex32(want);
            }
            errors++;
        }
    }
    uint32_t t1 = video->clock_cnt;
    uart_puts(errors ? "\n  FAIL, " : "PASS, ");
    uart_putdec(errors);
    uart_puts(" words wrong, ");
    uart_putdec((t1 - t0) / CLOCK_PER_MS);
    uart_puts(" ms\n");
    char t[40], *q = fmt_str(t, errors ? "FAIL, " : "PASS, ");
    if (errors) { q = fmt_dec(q, errors); q = fmt_str(q, " wrong, "); }
    q = fmt_dec(q, (t1 - t0) / CLOCK_PER_MS);
    fmt_str(q, " ms");
    boot_test(T_PSRAM, t, errors ? UI_BAD : UI_OK);

    // Code in PSRAM: x * x + 1, written through the data L1, written back
    // with cbo.clean, fetched by the fetch L1 after fence.i.
    volatile uint32_t *code = PSRAM + (7u << 20) / 4u;
    code[0] = 0x02a50533u;   // mul  a0, a0, a0
    code[1] = 0x00150513u;   // addi a0, a0, 1
    code[2] = 0x00008067u;   // ret
    cache_clean((uint32_t)(uintptr_t)code, 12u);
    asm volatile("fence.i" ::: "memory");
    int (*fn)(int) = (int (*)(int))(uintptr_t)code;
    int r = fn(7);
    uart_puts("code in PSRAM: ");
    uart_puts(r == 50 ? "PASS" : "FAIL");
    boot_test(T_CODE, r == 50 ? "PASS" : "FAIL", r == 50 ? UI_OK : UI_BAD);
    uart_puts(" (7*7+1 = ");
    uart_putdec((uint32_t)r);
    uart_puts(")\n");
}

// -------------------------------------------------------------------------
// CPU benchmark: loops through volatile pointers (so every access stays),
// timed with clock_cnt. Each iteration handles one 64-byte line with its
// 16 accesses written out: a word loop spends about 4 cycles per word on
// the loop itself (28 MB/s), which hid what the memory does.
// -------------------------------------------------------------------------
#define BENCH_WORDS 128u
#define BENCH_REPS  256u
#define BENCH_BYTES (BENCH_WORDS * 4u * BENCH_REPS)   // 128 KB per test

static uint32_t bench_a[BENCH_WORDS] __attribute__((aligned(64)));
static uint32_t bench_b[BENCH_WORDS] __attribute__((aligned(64)));

static void cpu_bench(void) {
    volatile uint32_t *a = bench_a;
    volatile uint32_t *b = bench_b;
    uint32_t t0, sum = 0;

    uart_puts("cpu benchmark, 128 KB per test\n");

#define LINE16(op) op(0) op(1) op(2) op(3) op(4) op(5) op(6) op(7) \
                   op(8) op(9) op(10) op(11) op(12) op(13) op(14) op(15)
    // Copies load four words, then store them: a store right after its
    // load waits for the load's result (34 against 63 MB/s in the L1).
#define COPY4(dst, src, k) { uint32_t x0 = src[i + k], x1 = src[i + k + 1u], \
        x2 = src[i + k + 2u], x3 = src[i + k + 3u]; dst[i + k] = x0; \
        dst[i + k + 1u] = x1; dst[i + k + 2u] = x2; dst[i + k + 3u] = x3; }
#define COPY16(dst, src) COPY4(dst, src, 0u) COPY4(dst, src, 4u) \
                         COPY4(dst, src, 8u) COPY4(dst, src, 12u)
    t0 = video->clock_cnt;
    for (uint32_t r = 0; r < BENCH_REPS; r++)
        for (uint32_t i = 0; i < BENCH_WORDS; i += 16u) {
#define FILL_L1(k) a[i + k] = i ^ r;
            LINE16(FILL_L1)
        }
    print_rate("  fill (in L1):     ", BENCH_BYTES, video->clock_cnt - t0, T_FILL_L1);

    t0 = video->clock_cnt;
    for (uint32_t r = 0; r < BENCH_REPS; r++)
        for (uint32_t i = 0; i < BENCH_WORDS; i += 16u) { COPY16(b, a) }
    print_rate("  copy (in L1):     ", BENCH_BYTES, video->clock_cnt - t0, T_COPY_L1);

    // PSRAM, 128 KB regions (8x the data L1), 4 KB + 64 bytes apart so
    // source and destination don't share data L1 sets. Fill and copy
    // allocate each destination line with cbo.zero (Zicboz) before writing
    // it: the data L1 zeroes it instead of reading it from PSRAM (fill 48
    // against 36 MB/s with prefetch.w; zeroing alone runs at 92 MB/s).
    // Read prefetches the next line (Zicbop), so its refill runs while this
    // one is added up. Copy doesn't prefetch: the data L1 has one refill
    // slot, which the cbo.zero of the destination needs too, and copy
    // speed swings with the code and data layout (18-27 MB/s for the same
    // loop in test programs). (Inline asm with a memory clobber:
    // __builtin_prefetch isn't ordered against the volatile accesses.)
#define PREFETCH(insn, p) asm volatile(insn " 0(%0)" :: "r"(p) : "memory")
#define CBO_ZERO(p) asm volatile(".insn i 0x0F, 2, x0, %0, 4" :: "r"(p) : "memory")   // cbo.zero
    volatile uint32_t *pa = PSRAM + (4u << 20) / 4u;
    volatile uint32_t *pb = PSRAM + ((5u << 20) + 4096u + 64u) / 4u;
    t0 = video->clock_cnt;
    for (uint32_t i = 0; i < BENCH_BYTES / 4u; i += 16u) {
        CBO_ZERO(&pa[i]);
#define FILL(k) pa[i + k] = i + k;
        LINE16(FILL)
    }
    print_rate("  fill PSRAM:       ", BENCH_BYTES, video->clock_cnt - t0, T_FILL_PS);

    t0 = video->clock_cnt;
    for (uint32_t i = 0; i < BENCH_BYTES / 4u; i += 16u) {
        CBO_ZERO(&pb[i]);
        COPY16(pb, pa)
    }
    print_rate("  copy PSRAM->PSRAM:", BENCH_BYTES, video->clock_cnt - t0, T_COPY_PS);

    t0 = video->clock_cnt;
    for (uint32_t i = 0; i < BENCH_BYTES / 4u; i += 16u) {
        PREFETCH("prefetch.r", &pb[i + 16u]);
#define SUM(k) sum += pb[i + k];
        LINE16(SUM)
    }
    print_rate("  read PSRAM:       ", BENCH_BYTES, video->clock_cnt - t0, T_SUM_PS);
#undef FILL_L1
#undef FILL
#undef SUM
#undef COPY16
#undef COPY4
#undef LINE16
#undef PREFETCH
#undef CBO_ZERO

    uart_puts("  (checksum 0x");
    uart_puthex32(sum);
    uart_puts(")\n");
}

// -------------------------------------------------------------------------
// Audio: a start-up chime (two notes, E5 then B5, decaying triangle
// waves), then silence; generated 256 samples (one 1 KB half) at a time
// into two PSRAM buffers, refilled from the audio interrupt.
// -------------------------------------------------------------------------
// (In .bss, the top of PSRAM: the refills go on during the boot screen,
// while a program loads from the card into the rest.)
static uint32_t aud_buf[2][256] __attribute__((aligned(256)));
#define AUD_BUF(n)    ((uint32_t)(uintptr_t)aud_buf[n] - PSRAM_BASE)   // PSRAM offsets
static uint32_t aud_t, aud_phase1, aud_phase2;

static int32_t tri(uint32_t phase) {   // -32768..32767
    int32_t t = (int32_t)(phase >> 15);
    return (t < 65536 ? t : 131071 - t) - 32768;
}

// Envelope for a note starting at `start` samples: 0..256, a 5 ms attack
// then an exponential-ish decay (a quarter every ~90 ms).
static int32_t env(uint32_t t, uint32_t start) {
    if (t < start) return 0;
    t -= start;
    if (t < 240u) return (int32_t)(t * 256u / 240u);
    uint32_t q = (t - 240u) / 4300u, r = (t - 240u) % 4300u;
    if (q > 12u) return 0;
    int32_t a = 256 >> (q / 2u);
    if (q & 1u) a = a * 3 / 4;
    return a - (a / 4) * (int32_t)r / 4300;
}

static void audio_fill(uint32_t half) {
    volatile uint32_t *buf = PSRAM + AUD_BUF(half) / 4u;
    for (uint32_t i = 0; i < 256u; i++, aud_t++) {
        int32_t s = 0;
        if (aud_t < 48000u) {
            aud_phase1 += 58980000u;   // 659 Hz (E5): 2^32 * f / 48000
            aud_phase2 += 88390000u;   // 988 Hz (B5)
            s = (tri(aud_phase1) * env(aud_t, 0) + tri(aud_phase2) * env(aud_t, 5760u)) / 1536;
        }
        buf[i] = (uint16_t)s | ((uint32_t)(uint16_t)s << 16);
    }
    cache_clean(PSRAM_BASE + AUD_BUF(half), 1024u);
    ctrl->audio_ptr[half] = AUD_BUF(half);
}

// -------------------------------------------------------------------------
// Interrupts
// -------------------------------------------------------------------------
static volatile uint32_t vblank_count, audio_irq_count;

__attribute__((interrupt("machine")))
static void trap_handler(void) {
    uint32_t pending = ctrl->irq_pending;
    ctrl->irq_pending = pending;
    if (pending & IRQ_VBLANK) vblank_count++;
    if (pending & IRQ_AUDIO_A) { audio_fill(0); audio_irq_count++; }
    if (pending & IRQ_AUDIO_B) { audio_fill(1); audio_irq_count++; }
}

static void irq_setup(void) {
    asm volatile("csrw mtvec, %0" :: "r"(&trap_handler));
    ctrl->irq_pending = 7u;
    ctrl->irq_enable = IRQ_VBLANK | IRQ_AUDIO_A | IRQ_AUDIO_B;
    asm volatile("csrs mie, %0" :: "r"(1u << 11));      // machine external
    asm volatile("csrs mstatus, %0" :: "r"(1u << 3));   // MIE
}

// -------------------------------------------------------------------------
// SPI flash (P25Q32U, 4 MB): JEDEC ID and a peek at the start. (Erase /
// program / verify were checked on the last sector; see README.)
// -------------------------------------------------------------------------
static void flash_read(uint32_t addr, uint8_t *buf, uint32_t n) {
    SPI_CTRL = SPI_FLASH_OE | SPI_CS_FLASH;
    spi_xfer(0x03u);
    spi_xfer(addr >> 16);
    spi_xfer(addr >> 8);
    spi_xfer(addr);
    for (uint32_t i = 0; i < n; i++) buf[i] = (uint8_t)spi_xfer(0);
    SPI_CTRL = SPI_FLASH_OE;
}

static void spi_flash_test(void) {
    sd_stop();   // the SD card may still be in a multi-block read
    uint32_t sd_div = SPI_DIV;   // (High Speed: restored at the end)
    SPI_DIV = 0;   // 18 MHz
    SPI_CTRL = SPI_FLASH_OE | SPI_CS_FLASH;
    spi_xfer(0x9Fu);
    uint32_t id = spi_xfer(0) << 16;
    id |= spi_xfer(0) << 8;
    id |= spi_xfer(0);
    SPI_CTRL = SPI_FLASH_OE;

    uint8_t buf[16];
    flash_read(0, buf, 16);
    SPI_CTRL = 0;   // release the pins (the FPGA's MSPI pins)

    uart_puts("spi flash: JEDEC id 0x");
    uart_puthex32(id);
    uart_puts(id == 0x856016u ? " (P25Q32U), first bytes:" : " (unexpected), first bytes:");
    boot_sys(SYS_FLASH, id == 0x856016u ? "76 KB user flash, 4 MB SPI (P25Q32U)" : "76 KB user flash, SPI flash not found",
             id == 0x856016u ? UI_TEXT : UI_WARN);
    for (uint32_t i = 0; i < 16; i++) {
        uart_putc(' ');
        uart_putc("0123456789ABCDEF"[buf[i] >> 4]);
        uart_putc("0123456789ABCDEF"[buf[i] & 15u]);
    }
    uart_puts("\n");
    SPI_DIV = sd_div;
}

// -------------------------------------------------------------------------
// SD card: initialization (sd.c), then FatFs (read-only, exFAT/FAT): volume,
// root directory, and the read speed on the first sizeable file.
// -------------------------------------------------------------------------
static void uart_puthex8(uint32_t v) {
    uart_putc("0123456789ABCDEF"[(v >> 4) & 15u]);
    uart_putc("0123456789ABCDEF"[v & 15u]);
}

static FATFS fs;
static uint8_t file_buf[4096];
static char first_file[2 * FF_MAX_LFN + 2];   // first file >= 64 KB (path)

// Lists a directory (up to 20 entries), and its subdirectories one level
// down; remembers the first file of at least 64 KB.
static void list_dir(const char *path, uint32_t depth) {
    DIR dir;
    FILINFO fno;
    if (f_opendir(&dir, path) != FR_OK) return;
    for (uint32_t n = 0; n < 20u && f_readdir(&dir, &fno) == FR_OK && fno.fname[0]; n++) {
        for (uint32_t d = 0; d <= depth; d++) uart_puts("    ");
        char sub[2 * FF_MAX_LFN + 2];
        uint32_t k = 0;
        for (const char *s = path; *s && k < sizeof(sub) - 2u; s++) sub[k++] = *s;
        if (k > 1u) sub[k++] = '/';
        for (const char *s = fno.fname; *s && k < sizeof(sub) - 1u; s++) sub[k++] = *s;
        sub[k] = 0;
        if (fno.fattrib & AM_DIR) {
            uart_puts("<dir>      ");
            uart_puts(fno.fname);
            uart_puts("\n");
            if (depth == 0) list_dir(sub, 1);
        } else {
            uint32_t kb = (uint32_t)((fno.fsize + 1023u) / 1024u);
            uart_putdec(kb);
            uart_puts(" KB");
            for (uint32_t d = kb < 10u ? 1u : kb < 100u ? 2u : kb < 1000u ? 3u : kb < 10000u ? 4u : 5u; d < 8u; d++) uart_putc(' ');
            uart_puts(fno.fname);
            uart_puts("\n");
            if (!first_file[0] && fno.fsize >= 65536u)
                for (uint32_t j = 0; j <= k; j++) first_file[j] = sub[j];
        }
    }
    f_closedir(&dir);
}

static int sd_ok;

static void sd_test(void) {
    sd_info_t info;
    int e = sd_init(&info);
    uart_puts("sd card: CMD0 ");
    uart_puthex8(info.r1_cmd0);
    uart_puts(", CMD8 ");
    uart_puthex8(info.r1_cmd8);
    uart_puts("/");
    uart_puthex32(info.r7);
    uart_puts(", ACMD41 ");
    uart_puthex8(info.r1_acmd41);
    uart_puts(" after ");
    uart_putdec(info.acmd41_tries);
    uart_puts(" tries (");
    uart_putdec(info.acmd41_ms);
    uart_puts(" ms), OCR ");
    uart_puthex32(info.ocr);
    uart_puts(info.block_addr ? " SDHC/SDXC, " : " SDSC, ");
    uart_putdec(info.sectors / 2048u);
    uart_puts(info.high_speed ? " MB, High Speed (36 MHz)\n" : " MB, 18 MHz\n");
    if (e) {
        boot_sys(SYS_SD, "not found", UI_WARN);
        boot_test(T_SD, "no card", UI_DIM);
        uart_puts("  init failed at step ");
        uart_putdec((uint32_t)e);
        uart_puts("\n");
        return;
    }

    FRESULT fr = f_mount(&fs, "", 1);
    if (fr != FR_OK) {
        boot_sys(SYS_SD, "no filesystem", UI_WARN);
        boot_test(T_SD, "-", UI_DIM);
        uart_puts("  mount failed, FRESULT ");
        uart_putdec(fr);
        uart_puts("\n");
        return;
    }
    static const char *const types[] = {"?", "FAT12", "FAT16", "FAT32", "exFAT"};
    char label[34];
    DWORD serial = 0;
    if (f_getlabel("", label, &serial) != FR_OK) label[0] = 0;
    uart_puts("  ");
    uart_puts(fs.fs_type <= 4 ? types[fs.fs_type] : "?");
    uart_puts(" volume \"");
    uart_puts(label);
    uart_puts("\", serial ");
    uart_puthex32(serial);
    uart_puts(", cluster ");
    uart_putdec(fs.csize * 512u);
    uart_puts(" bytes\n");
    sd_ok = 1;
    {
        char t[64], *q = fmt_dec(t, info.sectors / 2048u / 1024u);
        q = fmt_str(q, ".");
        q = fmt_dec(q, info.sectors / 2048u % 1024u * 10u / 1024u);
        q = fmt_str(q, " GB ");
        q = fmt_str(q, fs.fs_type <= 4 ? types[fs.fs_type] : "?");
        if (label[0]) { q = fmt_str(q, " \""); q = fmt_str(q, label); q = fmt_str(q, "\""); }
        boot_sys(SYS_SD, t, UI_TEXT);
    }

    uart_puts("  files:\n");
    first_file[0] = 0;
    list_dir("/", 0);

    const char *first = first_file;
    if (first[0]) {
        FIL f;
        if (f_open(&f, first, FA_READ) == FR_OK) {
            uint32_t total = 0, t0 = video->clock_cnt;
            UINT got;
            while (total < (1u << 20) && f_read(&f, file_buf, sizeof(file_buf), &got) == FR_OK && got)
                total += got;
            uint32_t us = (video->clock_cnt - t0) / CLOCK_PER_US;
            f_close(&f);
            uart_puts("  read ");
            uart_putdec(total / 1024u);
            uart_puts(" KB of \"");
            uart_puts(first);
            uart_puts("\" in ");
            uart_putdec(us / 1000u);
            uart_puts(" ms (");
            uart_putdec(us ? total / us : 0);
            uart_puts(".");
            uart_putdec(us ? (total % us) * 10u / us : 0);
            uart_puts(" MB/s)\n");
            char t[24];
            fmt_rate(t, total, us * CLOCK_PER_US);
            boot_test(T_SD, t, UI_TEXT);
        }
    }
}

// -------------------------------------------------------------------------
// Store widths through the data L1: bytes / halfwords / words into a cached
// PSRAM buffer, read back as bytes. (Byte enables on the data L1's block
// RAMs once corrupted lane 0; see README.)
// -------------------------------------------------------------------------
static void store_width_test(void) {
    volatile uint8_t  *b8  = (volatile uint8_t  *)(uintptr_t)(PSRAM_BASE + (3u << 20));
    volatile uint16_t *b16 = (volatile uint16_t *)(uintptr_t)(PSRAM_BASE + (3u << 20));
    volatile uint32_t *b32 = (volatile uint32_t *)(uintptr_t)(PSRAM_BASE + (3u << 20));
    uint32_t errors = 0;
    for (uint32_t w = 0; w < 3; w++) {
        for (uint32_t i = 0; i < 1024u; i++) b32[i] = 0xDEADBEEFu;   // 4 KB
        for (uint32_t i = 0; i < 4096u; i++) {
            uint8_t v = (uint8_t)(i * 13u + w + 1u);
            if (w == 0) b8[i] = v;
            else if (w == 1 && !(i & 1u)) b16[i / 2u] = (uint16_t)(v | ((uint8_t)((i + 1u) * 13u + w + 1u) << 8));
            else if (w == 2 && !(i & 3u)) {
                uint32_t x = 0;
                for (uint32_t k = 0; k < 4u; k++) x |= (uint32_t)(uint8_t)((i + k) * 13u + w + 1u) << (8u * k);
                b32[i / 4u] = x;
            }
        }
        for (uint32_t i = 0; i < 4096u; i++)
            if (b8[i] != (uint8_t)(i * 13u + w + 1u)) errors++;
    }
    uart_puts("store widths (byte/half/word) through the data L1: ");
    uart_puts(errors ? "FAIL, " : "PASS, ");
    uart_putdec(errors);
    uart_puts(" bytes wrong\n");
    boot_test(T_STORE, errors ? "FAIL" : "PASS", errors ? UI_BAD : UI_OK);
}

int main(void) {
    uart_puts("Hello, world from VexiiRiscv on the Tang Nano 9K!\n");
    boot_screen_init();
    boot_sys(SYS_CPU, "VexiiRiscv RV32IM Zba Zicbop, 36 MHz", UI_TEXT);
    boot_sys(SYS_CACHE, "8 KB fetch, 16 KB data (write-back)", UI_TEXT);
    boot_sys(SYS_MEM, "8 MB HyperRAM, 144 MHz DDR", UI_TEXT);
    boot_sys(SYS_VIDEO, "720x480 59.94 Hz HDMI", UI_TEXT);
    boot_sys(SYS_AUDIO, "48 kHz 16-bit stereo (HDMI)", UI_TEXT);
    // The tests and benchmarks run before the interrupts start: the chime's
    // interrupt alone took half the CPU and halved the numbers.
    store_width_test();
#ifndef NO_SD_TEST
    sd_test();
#else
    uart_puts("sd card: test disabled (NO_SD_TEST)\n");
#endif
    psram_cached_test();
    cpu_bench();

    audio_fill(0);
    audio_fill(1);
    irq_setup();
    ctrl->audio_ctrl = 1u;   // the chime: ready

    uint32_t t0 = video->clock_cnt, v0 = vblank_count, a0 = audio_irq_count;
    while (video->clock_cnt - t0 < CLOCK_HZ) {   // 1 s
    }
    uart_puts("after 1 s: ");
    uart_putdec(vblank_count - v0);
    uart_puts(" vblank interrupts, ");
    uart_putdec(audio_irq_count - a0);
    uart_puts(" audio interrupts\n");

    // The SPI flash sits on the FPGA's MSPI pins: only touch it well after
    // boot, clear of openFPGALoader's check after it reloads the FPGA (a
    // flash write's CRC check has failed while firmware drove those pins).
    spi_flash_test();

    boot_browser(sd_ok);   // doesn't return
    return 0;
}
