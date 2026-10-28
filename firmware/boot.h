// Boot screen and program browser (boot.c): an 8 bpp framebuffer with the
// system information and self-test results, and a browser for .bin
// programs on the SD card.
#ifndef BOOT_H
#define BOOT_H

#include <stdint.h>

// Rows of the two information sections (system, then tests).
enum { SYS_CPU, SYS_CACHE, SYS_MEM, SYS_FLASH, SYS_VIDEO, SYS_AUDIO, SYS_FW, SYS_SD, SYS_USB0, SYS_USB1, SYS_ROWS };
enum { T_STORE, T_PSRAM, T_CODE, T_FILL_L1, T_COPY_L1, T_FILL_PS, T_COPY_PS, T_SUM_PS, T_SD, T_ROWS };

// Clears the screen, draws the title, logo and labels ("..." for values
// not known yet) and turns the video on.
void boot_screen_init(void);

// Sets a value in the system section (SYS_*) or the test section (T_*),
// in colour (UI_* in assets.h).
void boot_sys(uint32_t row, const char *value, uint32_t colour);
void boot_test(uint32_t row, const char *value, uint32_t colour);

// Formats into buf (returns the end): a decimal number, and "x.y MB/s" for
// bytes moved in the given clock ticks (CLOCK_HZ).
char *fmt_dec(char *buf, uint32_t v);
char *fmt_rate(char *buf, uint32_t bytes, uint32_t ticks);
char *fmt_str(char *buf, const char *s);

// The browser: lists directories and .bin files on the SD card, starts the
// chosen one; also watches the USB ports and feeds the serial loader.
// Doesn't return.
void boot_browser(int sd_ok);

#endif
