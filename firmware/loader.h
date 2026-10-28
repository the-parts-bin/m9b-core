// Serial loader (loader.c): tools/run.py sends a program over the UART,
// which is copied into memory and started.
//
// Protocol (little-endian):
//   host -> board, 115200 baud: "\x1bM9BLOAD", then one byte: the bit
//                               period for the transfer in CPU clock cycles
//                               (36 MHz: 12: 3 Mbaud, 24: 1.5 M, 36: 1 M,
//                               39: 921600; see clock.h)
//   board -> host, 115200:      "READY\n", then switches to that rate
//   host -> board, fast:        frames: 0xA5, block (2 bytes), length (2,
//                               <= 2048), data, checksum (4). First the
//                               header, block 0xFFFE: load address, total
//                               length; then blocks 0, 1, ... of 2048 bytes
//                               (the last one shorter), in order.
//   board -> host, fast:        'K' after a good frame (also for a repeat
//                               of the last one), 'N' after a bad one (the
//                               board first waits for 5 ms of silence, then
//                               the host sends the frame again).
//   board -> host, fast:        "OK <bytes> <retries>\n" or "BAD ...", then
//                               115200 after 20 ms.
// The checksum: a = 1, b = 0; per byte a += byte, b += a;
// sum = a ^ (b << 16) ^ (b >> 16) (32-bit arithmetic).
// A header whose range isn't within LOAD_BASE..LOAD_LIMIT ends the transfer
// ("loader: doesn't fit"); a data block beyond the header's length is bad
// ('N', why 7) and written nowhere.
// On OK the board disables interrupts, audio and video, cleans the loaded
// range from the data cache, runs fence.i and jumps to the load address.
#ifndef LOADER_H
#define LOADER_H

#include <stdint.h>

#include "m9b_map.h"

// Programs load at LOAD_BASE (the start of PSRAM, where ../runtime/m9b.ld
// links them) and may reach up to LOAD_LIMIT: above it are the boot
// screen's framebuffer (+7.5 MB, boot.c) and the firmware's own data and
// stack (the top 128 KB, link.ld), both free once the program runs.
#define LOAD_BASE  M9B_PSRAM_BASE
#define LOAD_LIMIT (M9B_PSRAM_BASE + 0x780000u)

// Feed each received byte; returns 1 when the magic string is complete.
int loader_feed(int c);

// Receive and start a program (returns only on failure).
void loader_run(void);

// Starts a program loaded at addr (len bytes): interrupts, audio and video
// off, the range cleaned from the data cache, fence.i, jump. Doesn't return.
void loader_start(uint32_t addr, uint32_t len);

#endif
