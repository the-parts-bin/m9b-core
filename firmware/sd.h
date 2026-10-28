// SPI master and SD card (SPI mode) driver; see rtl/spi.v and README.
#ifndef SD_H
#define SD_H

#include <stdint.h>
#include "m9b_map.h"

#define SPI_DATA     (*(volatile uint32_t*)M9B_SPI)
#define SPI_CTRL     (*(volatile uint32_t*)(M9B_SPI + 0x4u))
#define SPI_DIV      (*(volatile uint32_t*)(M9B_SPI + 0x8u))
#define SPI_STREAM   (*(volatile uint32_t*)(M9B_SPI + 0xCu))   // read: 4 bytes, and start the next 4
#define SPI_LAST     (*(volatile uint32_t*)(M9B_SPI + 0x1Cu))   // read: 4 bytes
#define SPI_CS_FLASH (1u << 0)
#define SPI_CS_SD    (1u << 1)
#define SPI_FLASH_OE (1u << 4)   // drive the flash pins (MSPI: release when done)
#define SPI_BUSY     (1u << 8)
// SPI_DIV bits above div: SCLK = CPU clock (36 MHz, the SD card only), its
// phase, and where MISO is sampled (see rtl/spi.v, README SD card).
#define SPI_DIV_FAST        (1u << 8)
#define SPI_DIV_FAST_INV    (1u << 9)    // SCLK high in the first half of the cycle
#define SPI_DIV_SAMPLE_MID  (1u << 10)   // sample MISO mid-cycle (not at its end)
#define SPI_DIV_SAMPLE_LATE (2u << 10)   // ... mid-cycle of the next cycle
// A card in High Speed changes MISO after the rising edge (default speed:
// after the falling one), so MISO is valid around the next rising edge:
#define SPI_DIV_HS          (SPI_DIV_FAST | SPI_DIV_SAMPLE_MID)

// Sends a byte, returns the byte received.
uint32_t spi_xfer(uint32_t b);

// What sd_init() found, step by step (R1 responses, 0xFF = none).
typedef struct {
    uint8_t  r1_cmd0, r1_cmd8, r1_cmd55, r1_acmd41;
    uint32_t r7;              // CMD8 echo (0x1AA for an SD v2 card)
    uint32_t acmd41_tries, acmd41_ms;
    uint32_t ocr;
    uint32_t sectors;         // capacity from the CSD (v2 only), 512-byte sectors
    uint8_t  block_addr;      // SDHC/SDXC: sector addressing
    uint8_t  high_speed;      // switched to High Speed (CMD6), SPI at 36 MHz
} sd_info_t;

// Initializes the card (400 kHz, then 18 MHz, or 36 MHz once switched to
// High Speed; -DSD_NO_HIGH_SPEED keeps 18). Returns 0 when ready;
// otherwise the step that failed: 1 CMD0, 2 ACMD41 timeout, 3 CMD58.
int sd_init(sd_info_t *info);

// Reads count 512-byte sectors from lba (CMD18, kept open while reads
// follow on: CS stays low between calls). Returns 0 on success.
int sd_read(uint32_t lba, uint8_t *buf, uint32_t count);

// Ends an open multi-block read (CMD12) and releases CS. Call it before
// using the SPI for anything else (the flash) or starting another program.
void sd_stop(void);
// Writes count 512-byte sectors to lba (CMD24, or CMD25 for more than
// one). Returns 0 on success.
int sd_write(uint32_t lba, const uint8_t *buf, uint32_t count);

#endif
