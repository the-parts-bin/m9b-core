// Boot screen and program browser (see boot.h).
//
// The screen is an 8 bpp framebuffer in PSRAM (FB_OFFSET, 768-byte lines so
// each starts on a 256-byte block), shown through the line table as 480
// plain 8 bpp lines. Text is drawn in software in Pixel Operator (regular
// and bold, a proportional 16 px pixel font, CC0; tables in assets.h);
// everything drawn is cleaned from the data cache for the video DMA. Palette: UI
// colours 0..15, the logo 32..255 (gen_assets.py).
//
// Programs: *.bin files (and directories) on the SD card; the chosen one is
// read to LOAD_ADDR and started like a serially loaded one (loader_start).
// Keys: a USB keyboard on either port, or the UART (arrows as ESC [ A..D,
// Enter, Backspace); the serial loader keeps working.
#include "boot.h"

#include "assets.h"
#include "clock.h"
#include "fatfs/ff.h"
#include "loader.h"
#include "m9b_map.h"

#define PSRAM_BASE    M9B_PSRAM_BASE
#define FB_OFFSET     0x780000u                     // 7.5 MB: clear of the boot tests
#define FB            ((uint8_t *)(PSRAM_BASE + FB_OFFSET))
#define FB_STRIDE     768u
#define FB_W          720u
#define FB_H          480u
#define LOAD_ADDR     LOAD_BASE                     // loader.h
#define LOAD_MAX      (LOAD_LIMIT - LOAD_BASE)      // 7.5 MB: up to the framebuffer
_Static_assert(PSRAM_BASE + FB_OFFSET == LOAD_LIMIT, "programs load up to the framebuffer");
_Static_assert(FB_OFFSET + FB_STRIDE * FB_H <= 0x7E0000u, "the framebuffer ends below the firmware's RAM (link.ld)");

#define VRAM          ((volatile uint32_t*)M9B_VRAM)
#define VRAM_PALETTE  (VRAM + 512)
#define VRAM_TABLE    (VRAM + 640)
#define LINE_8BPP     (2u << 22)
#define VIDEO_CTRL    (*(volatile uint32_t*)M9B_CTRL)
#define CLOCK_CNT     (*(volatile uint32_t*)(M9B_TIMING + 0xCu))   // CLOCK_HZ
#define UART_DATA     (*(volatile uint32_t*)M9B_UART)
#define UART_RX_VALID (1u << 8)
#define UART_STATUS   (*(volatile uint32_t*)(M9B_UART + 0x4u))   // bit 0: TX busy
#define USB_REG(p, o) (*(volatile uint32_t*)(M9B_USB + 0x20u * (p) + (o)))
#define MS            CLOCK_PER_MS

// Layout (pixels): title and logo on top; the left column has the system
// information and below it the self-test, the right one (under the logo)
// the program browser and two status lines.
#define MARGIN        24u
#define LOGO_X        (FB_W - MARGIN - LOGO_SIZE)
#define LOGO_Y        14u
#define COL1_X        MARGIN
#define COL1_END      400u
#define COL2_X        416u
#define COL2_END      (FB_W - MARGIN)
#define SYS_DX        (9u * 8u)       // label width, system rows
#define TEST_DX       (15u * 8u)      // test rows
#define SYS_HEAD_Y    100u
#define SYS_Y         (SYS_HEAD_Y + 24u)            // first system row
#define TEST_HEAD_Y   (SYS_Y + 16u * SYS_ROWS + 8u)
#define TEST_Y        (TEST_HEAD_Y + 24u)           // first test row
#define LIST_TITLE_Y  160u
#define LIST_Y        (LIST_TITLE_Y + 24u)
#define LIST_ROWS     14u
#define STATUS_Y      (TEST_Y + 16u * T_ROWS - 32u)   // two lines, level with the last test row
#define SIZE_W        64u             // file size column

// -------------------------------------------------------------------------
// Drawing
// -------------------------------------------------------------------------
static void fb_clean(uint32_t y0, uint32_t y1) {
    uint32_t a = (uint32_t)(FB + y0 * FB_STRIDE), b = (uint32_t)(FB + y1 * FB_STRIDE);
    for (a &= ~63u; a < b; a += 64u)
        asm volatile("cbo.clean (%0)" :: "r"(a) : "memory");
}

static void fill(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t c) {
    for (uint32_t j = 0; j < h; j++) {
        uint8_t *p = FB + (y + j) * FB_STRIDE + x;
        for (uint32_t i = 0; i < w; i++) p[i] = (uint8_t)c;
    }
}

typedef struct {
    const uint8_t *adv;           // advance width, ASCII 32..126
    const uint16_t (*rows)[16];   // 16 rows, bit 15 leftmost
} font_t;

static const font_t REGULAR = {font_regular_adv, font_regular_rows};
static const font_t BOLD = {font_bold_adv, font_bold_rows};

static uint32_t glyph(char ch) {
    return ch >= 32 && ch < 127 ? (uint32_t)(ch - 32) : (uint32_t)('?' - 32);
}

static uint32_t text_width(const font_t *f, const char *s) {
    uint32_t w = 0;
    while (*s) w += f->adv[glyph(*s++)];
    return w;
}

// A character at (x, y), background included, scale 1 or 2; returns the
// next x.
static uint32_t draw_char(const font_t *f, uint32_t x, uint32_t y, char ch, uint32_t fg, uint32_t bg,
                          uint32_t scale) {
    uint32_t g = glyph(ch), w = f->adv[g] * scale;
    for (uint32_t r = 0; r < 16u * scale; r++) {
        uint32_t bits = f->rows[g][r / scale];
        uint8_t *p = FB + (y + r) * FB_STRIDE + x;
        for (uint32_t c = 0; c < w; c++)
            p[c] = (uint8_t)((bits & (0x8000u >> (c / scale))) ? fg : bg);
    }
    return x + w;
}

// Text at (x, y), the rest of the field up to x_end cleared to bg. Text that
// doesn't fit ends in "..." instead of a cut glyph.
static void draw_text_f(const font_t *f, uint32_t x, uint32_t y, uint32_t x_end, const char *s,
                        uint32_t fg, uint32_t bg) {
    uint32_t dots = 3u * f->adv[glyph('.')];
    int fits = x + text_width(f, s) <= x_end;
    while (*s) {
        uint32_t w = f->adv[glyph(*s)];
        if (!fits && x + w + dots > x_end) {
            for (int i = 0; i < 3 && x + f->adv[glyph('.')] <= x_end; i++) x = draw_char(f, x, y, '.', fg, bg, 1);
            break;
        }
        x = draw_char(f, x, y, *s++, fg, bg, 1);
    }
    if (x < x_end) fill(x, y, x_end - x, 16, bg);
}

static void draw_text(uint32_t x, uint32_t y, uint32_t x_end, const char *s, uint32_t fg, uint32_t bg) {
    draw_text_f(&REGULAR, x, y, x_end, s, fg, bg);
}

static void draw_logo(void) {
    for (uint32_t y = 0; y < LOGO_SIZE; y++)
        for (uint32_t x = 0; x < LOGO_SIZE; x++)
            FB[(LOGO_Y + y) * FB_STRIDE + LOGO_X + x] = logo_pixels[y * LOGO_SIZE + x];
}

// -------------------------------------------------------------------------
// Formatting
// -------------------------------------------------------------------------
char *fmt_str(char *p, const char *s) {
    while (*s) *p++ = *s++;
    *p = 0;
    return p;
}

char *fmt_dec(char *p, uint32_t v) {
    char t[10];
    int n = 0;
    do { t[n++] = (char)('0' + v % 10u); v /= 10u; } while (v);
    while (n) *p++ = t[--n];
    *p = 0;
    return p;
}

char *fmt_rate(char *p, uint32_t bytes, uint32_t ticks) {
    uint32_t us = ticks / CLOCK_PER_US;
    if (!us) us = 1u;
    uint32_t mb10 = (bytes / us) * 10u + (bytes % us) * 10u / us;
    p = fmt_dec(p, mb10 / 10u);
    *p++ = '.';
    p = fmt_dec(p, mb10 % 10u);
    return fmt_str(p, " MB/s");
}

// -------------------------------------------------------------------------
// The information screen
// -------------------------------------------------------------------------
static const char *const sys_labels[SYS_ROWS] = {
    "CPU", "Caches", "Memory", "Flash", "Video", "Audio", "Firmware", "SD card", "USB 0", "USB 1"};
static const char *const test_labels[T_ROWS] = {
    "Store widths", "PSRAM 1 MB", "Code in PSRAM", "Fill (L1)", "Copy (L1)",
    "Fill PSRAM", "Copy PSRAM", "Read PSRAM", "SD read"};

void boot_sys(uint32_t row, const char *value, uint32_t colour) {
    uint32_t y = SYS_Y + 16u * row;
    draw_text(COL1_X + SYS_DX, y, COL1_END, value, colour, UI_BG);
    fb_clean(y, y + 16u);
}

void boot_test(uint32_t row, const char *value, uint32_t colour) {
    uint32_t y = TEST_Y + 16u * row;
    draw_text(COL1_X + TEST_DX, y, COL1_END, value, colour, UI_BG);
    fb_clean(y, y + 16u);
}

static void heading(uint32_t x, uint32_t y, uint32_t x_end, const char *s) {
    draw_text_f(&BOLD, x, y, x_end, s, UI_HEAD, UI_BG);
    fill(x, y + 17u, x_end - x, 1, UI_LINE);
}

void boot_screen_init(void) {
    VIDEO_CTRL = 0;
    for (uint32_t i = 0; i < 128u; i++)
        VRAM_PALETTE[i] = boot_palette[2u * i] | (uint32_t)boot_palette[2u * i + 1u] << 16;
    fill(0, 0, FB_W, FB_H, UI_BG);

    // Title (2x font), subtitle, logo.
    uint32_t x = MARGIN;
    x = draw_char(&BOLD, x, 28, 'm', UI_ACCENT, UI_BG, 2);
    x = draw_char(&BOLD, x, 28, '9', UI_ACCENT2, UI_BG, 2);
    draw_char(&BOLD, x, 28, 'b', UI_ACCENT, UI_BG, 2);
    draw_text_f(&BOLD, MARGIN, 72, LOGO_X - 8u, "A RISC-V computer on the Tang Nano 9K", UI_TEXT, UI_BG);
    draw_logo();

    heading(COL1_X, SYS_HEAD_Y, COL1_END, "SYSTEM");
    heading(COL1_X, TEST_HEAD_Y, COL1_END, "SELF-TEST AND BENCHMARKS");
    for (uint32_t r = 0; r < SYS_ROWS; r++) {
        draw_text(COL1_X, SYS_Y + 16u * r, COL1_X + SYS_DX, sys_labels[r], UI_DIM, UI_BG);
        draw_text(COL1_X + SYS_DX, SYS_Y + 16u * r, COL1_END, "...", UI_LINE, UI_BG);
    }
    draw_text(COL1_X + SYS_DX, SYS_Y + 16u * SYS_FW, COL1_END, "built " __DATE__, UI_TEXT, UI_BG);
    for (uint32_t r = 0; r < T_ROWS; r++) {
        draw_text(COL1_X, TEST_Y + 16u * r, COL1_X + TEST_DX, test_labels[r], UI_DIM, UI_BG);
        draw_text(COL1_X + TEST_DX, TEST_Y + 16u * r, COL1_END, "...", UI_LINE, UI_BG);
    }
    fb_clean(0, FB_H);

    for (uint32_t y = 0; y < FB_H; y++)
        VRAM_TABLE[y] = LINE_8BPP | ((FB_OFFSET + y * FB_STRIDE) >> 8);
    VIDEO_CTRL = 1;
}

// -------------------------------------------------------------------------
// USB: device types on the information screen, and keys
// -------------------------------------------------------------------------
enum { K_NONE, K_UP, K_DOWN, K_ENTER, K_BACK, K_PGUP, K_PGDN, K_HOME, K_END };

static uint32_t usb_type[2] = {0xFFu, 0xFFu}, usb_count[2];
static uint8_t usb_keys[2][4];
static uint32_t held_key, held_since, held_next;   // key repeat (USB)

static uint32_t hid_to_key(uint32_t code) {
    switch (code) {
    case 0x52: return K_UP;
    case 0x51: return K_DOWN;
    case 0x28: case 0x58: return K_ENTER;   // Enter, keypad Enter
    case 0x2A: case 0x29: return K_BACK;    // Backspace, Esc
    case 0x4B: return K_PGUP;
    case 0x4E: return K_PGDN;
    case 0x4A: return K_HOME;
    case 0x4D: return K_END;
    default: return K_NONE;
    }
}

// Updates the USB rows; returns a key newly pressed (or repeating).
static uint32_t usb_poll(void) {
    static const char *const types[] = {"none", "keyboard", "mouse", "gamepad"};
    uint32_t key = K_NONE;
    for (uint32_t p = 0; p < 2u; p++) {
        uint32_t st = USB_REG(p, 0), type = st & 3u, count = st >> 8 & 0xFFu;
        if (type != usb_type[p]) {
            usb_type[p] = type;
            boot_sys(SYS_USB0 + p, types[type], type ? UI_OK : UI_DIM);
        }
        if (type != 1u || count == usb_count[p]) continue;
        usb_count[p] = count;
        uint32_t k = USB_REG(p, 4);
        uint8_t keys[4] = {(uint8_t)(k >> 8), (uint8_t)(k >> 16), (uint8_t)(k >> 24), (uint8_t)USB_REG(p, 8)};
        for (uint32_t i = 0; i < 4u; i++) {
            if (keys[i] < 4u) continue;
            int was = 0;
            for (uint32_t j = 0; j < 4u; j++) was |= usb_keys[p][j] == keys[i];
            uint32_t kk = hid_to_key(keys[i]);
            if (!was && kk) {
                key = kk;
                held_key = kk;
                held_since = held_next = CLOCK_CNT;
            }
        }
        int still = 0;
        for (uint32_t i = 0; i < 4u; i++) still |= held_key && hid_to_key(keys[i]) == held_key;
        if (!still) held_key = K_NONE;
        for (uint32_t i = 0; i < 4u; i++) usb_keys[p][i] = keys[i];
    }
    // Repeat a held arrow: after 400 ms, every 60 ms.
    if (!key && held_key && CLOCK_CNT - held_since > 400u * MS && CLOCK_CNT - held_next > 60u * MS) {
        held_next = CLOCK_CNT;
        key = held_key;
    }
    return key;
}

// The screen over the UART, for tools/m9bctl.py shot: "\nM9BSHOT\n", the
// width and height (16-bit), 256 RGB565 palette entries, the pixels.
static void uart_put(uint32_t c) {
    while (UART_STATUS & 1u) {}
    UART_DATA = c & 0xFFu;
}

static void screenshot(void) {
    for (const char *t = "\nM9BSHOT\n"; *t; t++) uart_put((uint8_t)*t);
    uart_put(FB_W); uart_put(FB_W >> 8); uart_put(FB_H); uart_put(FB_H >> 8);
    for (uint32_t i = 0; i < 256u; i++) {
        uint32_t c = boot_palette[i];
        uart_put(c); uart_put(c >> 8);
    }
    for (uint32_t y = 0; y < FB_H; y++)
        for (uint32_t x = 0; x < FB_W; x++) uart_put(FB[y * FB_STRIDE + x]);
}

// Keys from the UART (also fed to the serial loader).
static uint32_t uart_poll(void) {
    static uint32_t esc;   // 0, 1 after ESC, 2 after ESC [, 3 after ESC [ digit
    static uint32_t digit;
    uint32_t d = UART_DATA;
    if (!(d & UART_RX_VALID)) return K_NONE;
    char c = (char)d;
    if (c == 0x1C) { screenshot(); return K_NONE; }
    if (loader_feed(c)) loader_run();   // returns only if the load failed
    if (esc == 1u) { esc = c == '[' ? 2u : 0u; return K_NONE; }
    if (esc == 2u) {
        esc = 0;
        if (c == 'A') return K_UP;
        if (c == 'B') return K_DOWN;
        if (c == 'H') return K_HOME;
        if (c == 'F') return K_END;
        if (c >= '0' && c <= '9') { digit = (uint32_t)(c - '0'); esc = 3; }
        return K_NONE;
    }
    if (esc == 3u) {
        esc = 0;
        if (c != '~') return K_NONE;
        return digit == 5u ? K_PGUP : digit == 6u ? K_PGDN : digit == 1u ? K_HOME : digit == 4u ? K_END : K_NONE;
    }
    if (c == 27) { esc = 1; return K_NONE; }
    if (c == '\r' || c == '\n') return K_ENTER;
    if (c == 0x7F || c == 0x08) return K_BACK;
    if (c == 'k') return K_UP;
    if (c == 'j') return K_DOWN;
    return K_NONE;
}

// -------------------------------------------------------------------------
// The browser
// -------------------------------------------------------------------------
#define MAX_ENTRIES 64u
#define NAME_MAX    64u

typedef struct {
    char name[NAME_MAX];
    uint32_t size;
    uint8_t dir;
} entry_t;

static entry_t entries[MAX_ENTRIES];
static uint32_t n_entries, sel, top;
static char cwd[256] = "/";

static int is_bin(const char *s) {
    uint32_t n = 0;
    while (s[n]) n++;
    if (n < 5u) return 0;
    const char *e = s + n - 4;
    return e[0] == '.' && (e[1] | 32) == 'b' && (e[2] | 32) == 'i' && (e[3] | 32) == 'n';
}

static int name_less(const entry_t *a, const entry_t *b) {
    if (a->dir != b->dir) return a->dir > b->dir;   // directories first
    for (uint32_t i = 0;; i++) {
        char x = a->name[i], y = b->name[i];
        if (x >= 'A' && x <= 'Z') x += 32;
        if (y >= 'A' && y <= 'Z') y += 32;
        if (x != y || !x) return x < y;
    }
}

static void read_dir(void) {
    static DIR dir;
    static FILINFO fi;
    n_entries = 0;
    sel = top = 0;
    if (cwd[1]) {   // not the root: ".." first
        fmt_str(entries[0].name, "..");
        entries[0].dir = 1;
        entries[0].size = 0;
        n_entries = 1;
    }
    if (f_opendir(&dir, cwd) != FR_OK) return;
    while (n_entries < MAX_ENTRIES && f_readdir(&dir, &fi) == FR_OK && fi.fname[0]) {
        if (fi.fattrib & (AM_HID | AM_SYS)) continue;
        int d = (fi.fattrib & AM_DIR) != 0;
        if (!d && !is_bin(fi.fname)) continue;
        entry_t *e = &entries[n_entries];
        uint32_t k = 0;
        for (; fi.fname[k] && k < NAME_MAX - 1u; k++) e->name[k] = fi.fname[k];
        e->name[k] = 0;
        e->dir = (uint8_t)d;
        e->size = (uint32_t)fi.fsize;
        // insertion sort (after "..")
        uint32_t i = n_entries++;
        entry_t t = *e;
        while (i > (cwd[1] ? 1u : 0u) && name_less(&t, &entries[i - 1u])) { entries[i] = entries[i - 1u]; i--; }
        entries[i] = t;
    }
    f_closedir(&dir);
}

// The status lines under the browser: a message, and a second line (or "").
static void status2(const char *s, const char *s2, uint32_t colour) {
    draw_text(COL2_X, STATUS_Y, COL2_END, s, colour, UI_BG);
    draw_text(COL2_X, STATUS_Y + 16u, COL2_END, s2, colour, UI_BG);
    fb_clean(STATUS_Y, STATUS_Y + 32u);
}

static void status(const char *s, uint32_t colour) {
    status2(s, "", colour);
}

static void draw_list(int sd_ok) {
    char t[300], *p;
    p = fmt_str(t, "PROGRAMS   sd:");
    fmt_str(p, cwd);
    heading(COL2_X, LIST_TITLE_Y, COL2_END, t);
    if (sel < top) top = sel;
    if (sel >= top + LIST_ROWS) top = sel - LIST_ROWS + 1u;
    for (uint32_t r = 0; r < LIST_ROWS; r++) {
        uint32_t i = top + r, y = LIST_Y + 16u * r;
        if (!sd_ok || i >= n_entries) {
            const char *msg = !sd_ok && r == 0 ? "(no SD card)" : n_entries == 0 && r == 0 ? "(no .bin files here)" : "";
            draw_text(COL2_X, y, COL2_END, msg, UI_DIM, UI_BG);
            continue;
        }
        const entry_t *e = &entries[i];
        uint32_t bg = i == sel ? UI_SELBG : UI_BG;
        fill(COL2_X, y, 16, 16, bg);
        draw_char(&BOLD, COL2_X + 2u, y, i == sel ? '>' : ' ', UI_ACCENT, bg, 1);
        p = fmt_str(t, e->name);
        if (e->dir) fmt_str(p, "/");
        draw_text_f(i == sel ? &BOLD : &REGULAR, COL2_X + 16u, y, COL2_END - SIZE_W, t,
                    e->dir ? UI_ACCENT : UI_WHITE, bg);
        if (e->dir) {
            draw_text(COL2_END - SIZE_W, y, COL2_END, "", UI_DIM, bg);
        } else {
            p = fmt_dec(t, (e->size + 1023u) / 1024u);
            fmt_str(p, " KB");
            uint32_t w = text_width(&REGULAR, t);   // right-aligned
            fill(COL2_END - SIZE_W, y, SIZE_W - w, 16, bg);
            draw_text(COL2_END - w, y, COL2_END, t, UI_DIM, bg);
        }
    }
    // scroll marks
    fill(COL2_END - 8u, LIST_TITLE_Y, 8, 16, UI_BG);
    draw_char(&REGULAR, COL2_END - 8u, LIST_TITLE_Y, top > 0 ? '^' : ' ', UI_DIM, UI_BG, 1);
    fb_clean(LIST_TITLE_Y, LIST_Y + 16u * LIST_ROWS);
}

static void join(char *out, const char *dir, const char *name) {
    char *p = fmt_str(out, dir);
    if (p[-1] != '/') *p++ = '/';
    fmt_str(p, name);
}

static void enter_dir(const char *name) {
    if (name[0] == '.' && name[1] == '.' && !name[2]) {
        uint32_t n = 0;
        while (cwd[n]) n++;
        while (n > 1u && cwd[n - 1u] != '/') n--;
        cwd[n > 1u ? n - 1u : 1u] = 0;
    } else {
        char t[256];
        join(t, cwd, name);
        fmt_str(cwd, t);
    }
    read_dir();
}

static void run_file(const entry_t *e) {
    char path[320], msg[160], *p;
    join(path, cwd, e->name);
    if (e->size == 0 || e->size > LOAD_MAX) {
        p = fmt_str(msg, e->name);
        fmt_str(p, ": too big to load (7.5 MB at most)");
        status(msg, UI_BAD);
        return;
    }
    static FIL f;
    if (f_open(&f, path, FA_READ) != FR_OK) { status("can't open the file", UI_BAD); return; }
    uint8_t *dst = (uint8_t *)LOAD_ADDR;
    uint32_t done = 0, t0 = CLOCK_CNT;
    while (done < e->size) {
        UINT got;
        uint32_t n = e->size - done > 65536u ? 65536u : e->size - done;
        if (f_read(&f, dst + done, n, &got) != FR_OK || got == 0) break;
        done += got;
        p = fmt_str(msg, "loading ");
        p = fmt_str(p, e->name);
        p = fmt_str(p, "  ");
        p = fmt_dec(p, done / 1024u);
        p = fmt_str(p, " / ");
        p = fmt_dec(p, e->size / 1024u);
        fmt_str(p, " KB");
        status(msg, UI_WARN);
    }
    f_close(&f);
    if (done != e->size) { status("read error", UI_BAD); return; }
    p = fmt_str(msg, "starting ");
    p = fmt_str(p, e->name);
    p = fmt_str(p, " (");
    p = fmt_rate(p, done, CLOCK_CNT - t0);
    fmt_str(p, ")");
    status(msg, UI_OK);
    for (uint32_t t = CLOCK_CNT; CLOCK_CNT - t < 300u * MS;) {}
    loader_start(LOAD_ADDR, done);
}

void boot_browser(int sd_ok) {
    if (sd_ok) read_dir();
    draw_list(sd_ok);
    if (sd_ok) status2("Up/Down select, Enter run or open,", "Backspace back. Serial loader ready.", UI_DIM);
    else status2("No SD card: programs only through", "the serial loader.", UI_DIM);
    for (;;) {
        uint32_t k = usb_poll();
        if (!k) k = uart_poll();
        if (!k || !sd_ok) continue;
        if (k == K_UP && sel > 0) sel--;
        else if (k == K_DOWN && sel + 1u < n_entries) sel++;
        else if (k == K_PGUP) sel = sel > LIST_ROWS ? sel - LIST_ROWS : 0;
        else if (k == K_PGDN) sel = sel + LIST_ROWS < n_entries ? sel + LIST_ROWS : (n_entries ? n_entries - 1u : 0);
        else if (k == K_HOME) sel = 0;
        else if (k == K_END) sel = n_entries ? n_entries - 1u : 0;
        else if (k == K_BACK && cwd[1]) enter_dir("..");
        else if (k == K_ENTER && sel < n_entries) {
            if (entries[sel].dir) enter_dir(entries[sel].name);
            else run_file(&entries[sel]);
        }
        draw_list(sd_ok);
    }
}
