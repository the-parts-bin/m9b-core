// The m9b memory map (the CPU's physical addresses are 24 bits: anything at
// or above 16 MB traps). Shared by the firmware, the tools and every port
// (they all build with -I core/firmware); the linker scripts and the
// assembly start-up code repeat the numbers, as noted there.
//
//   0x000000 - 0x01FFFF  user flash (76 KB used, cached, read only): the
//                        firmware, reset vector 0
//   0x400000 - 0x47FFFF  I/O, uncached: one 64 KB window per device
//   0x800000 - 0xFFFFFF  PSRAM (8 MB, cached): programs load at its start
#ifndef M9B_MAP_H
#define M9B_MAP_H

#define M9B_FLASH_BASE  0x000000u
#define M9B_IO_BASE     0x400000u
#define M9B_PSRAM_BASE  0x800000u
#define M9B_PSRAM_SIZE  0x800000u

// I/O windows (see core/README.md for the registers in each)
#define M9B_UART        0x410000u   // UART: data, status, divider
#define M9B_VRAM        0x420000u   // video RAM: palette, line table
#define M9B_CTRL        0x430000u   // video/audio/interrupt control
#define M9B_TIMING      0x440000u   // video timing counters, CLOCK_CNT (+0xC)
#define M9B_SPI         0x450000u   // SPI: SD card and SPI flash
#define M9B_USB         0x460000u   // USB ports, 0x20 apart
#define M9B_PERF        0x470000u   // L1 bus counters (PERF_COUNTERS builds)

#endif
