// SPI master and SD card (SPI mode) driver; see sd.h.
#include "sd.h"

#include "clock.h"
#include "m9b_map.h"

#define CLOCK_CNT (*(volatile uint32_t*)(M9B_TIMING + 0xCu))   // CLOCK_HZ

uint32_t spi_xfer(uint32_t b) {
    SPI_DATA = b;
    while (SPI_CTRL & SPI_BUSY) {
    }
    return SPI_DATA;
}

static int block_addr;   // SDHC/SDXC: sector numbers; SDSC: byte addresses

// Reads keep one READ_MULTIPLE_BLOCK (CMD18) running while they are
// sequential: the card is left mid-transfer, CS low, with the next sector
// stream_next (it waits for the clock). sd_stop() ends it.
static int stream_open;
static uint32_t stream_next;

// Sends a command (CS low) and returns R1 (0xFF: no response).
static uint32_t sd_cmd(uint32_t cmd, uint32_t arg, uint32_t crc) {
    spi_xfer(0xFFu);
    spi_xfer(0x40u | cmd);
    spi_xfer(arg >> 24);
    spi_xfer(arg >> 16);
    spi_xfer(arg >> 8);
    spi_xfer(arg);
    spi_xfer(crc);
    uint32_t r = 0xFFu;
    for (uint32_t i = 0; i < 10u && (r & 0x80u); i++) r = spi_xfer(0xFFu);
    return r;
}

static void deselect(void) {
    SPI_CTRL = 0;
    spi_xfer(0xFFu);   // 8 clocks with CS high
}

// STOP_TRANSMISSION during a CMD18 (CS low): the card sends a stuff byte,
// R1, then holds MISO low while busy. Returns 1 if R1 was 0.
static int sd_cmd12(void) {
    spi_xfer(0x40u | 12u);
    for (uint32_t i = 0; i < 4u; i++) spi_xfer(0);
    spi_xfer(0x61u);
    spi_xfer(0xFFu);   // stuff byte
    uint32_t r = 0xFFu;
    for (uint32_t i = 0; i < 10u && (r & 0x80u); i++) r = spi_xfer(0xFFu);
    uint32_t t0 = CLOCK_CNT;   // busy (MISO low) until the card is done
    while (spi_xfer(0xFFu) != 0xFFu && CLOCK_CNT - t0 < CLOCK_HZ / 10u) {
    }
    return r == 0;
}

void sd_stop(void) {
    if (!stream_open) return;
    stream_open = 0;
    SPI_CTRL = SPI_CS_SD;
    sd_cmd12();
    deselect();
}

// Waits for the data token and reads n bytes of a data block (CS low).
static int sd_read_data(uint8_t *buf, uint32_t n) {
    uint32_t t0 = CLOCK_CNT, tok = 0xFFu;
    while (tok == 0xFFu && CLOCK_CNT - t0 < CLOCK_HZ / 10u)   // 100 ms
        tok = spi_xfer(0xFFu);
    if (tok != 0xFEu) return 0;
    if ((n & 3u) == 0) {
        // 32 bits at a time, the next transfer running while this one is
        // stored (SPI_STREAM); the last read starts none, so no bytes after
        // the block (CRC, then maybe the next block's token) are consumed.
        SPI_STREAM = 0;
        for (uint32_t i = 0; i < n; i += 4u) {
            uint32_t w = i + 4u < n ? SPI_STREAM : SPI_LAST;
            if (((uintptr_t)buf & 3u) == 0) {
                *(uint32_t *)(buf + i) = w;
            } else {
                buf[i] = (uint8_t)w;
                buf[i + 1u] = (uint8_t)(w >> 8);
                buf[i + 2u] = (uint8_t)(w >> 16);
                buf[i + 3u] = (uint8_t)(w >> 24);
            }
        }
    } else {
        for (uint32_t i = 0; i < n; i++) buf[i] = (uint8_t)spi_xfer(0xFFu);
    }
    spi_xfer(0xFFu);   // CRC, not checked
    spi_xfer(0xFFu);
    return 1;
}

int sd_init(sd_info_t *info) {
    info->r1_cmd8 = info->r1_cmd55 = info->r1_acmd41 = 0xFFu;
    info->r7 = info->ocr = info->sectors = 0;
    info->acmd41_tries = info->acmd41_ms = 0;
    info->block_addr = 0;
    info->high_speed = 0;

    // >= 74 clocks with CS high, at ~400 kHz.
    SPI_DIV = SPI_DIV_FOR(400000u);
    SPI_CTRL = 0;
    for (uint32_t i = 0; i < 10u; i++) spi_xfer(0xFFu);

    stream_open = 0;
    SPI_CTRL = SPI_CS_SD;
    info->r1_cmd0 = (uint8_t)sd_cmd(0u, 0, 0x95u);
    if (info->r1_cmd0 != 0x01u) {
        // A card left in a CMD18 (a program stopped without sd_stop(), or a
        // reset) is still sending data: stop it and try again.
        sd_cmd12();
        deselect();
        for (uint32_t i = 0; i < 10u; i++) spi_xfer(0xFFu);
        SPI_CTRL = SPI_CS_SD;
        info->r1_cmd0 = (uint8_t)sd_cmd(0u, 0, 0x95u);
    }
    if (info->r1_cmd0 != 0x01u) { deselect(); return 1; }

    info->r1_cmd8 = (uint8_t)sd_cmd(8u, 0x1AAu, 0x87u);
    for (uint32_t i = 0; i < 4u; i++) info->r7 = (info->r7 << 8) | spi_xfer(0xFFu);
    int v2 = info->r1_cmd8 == 0x01u && (info->r7 & 0xFFFu) == 0x1AAu;

    // ACMD41 until the card leaves idle (up to 3 s). CS has to be released
    // (with 8 clocks) between tries: the test card never became ready with
    // CS held low throughout.
    uint32_t t0 = CLOCK_CNT, r;
    do {
        deselect();
        SPI_CTRL = SPI_CS_SD;
        info->r1_cmd55 = (uint8_t)sd_cmd(55u, 0, 0x65u);
        r = sd_cmd(41u, v2 ? 0x40000000u : 0, 0x77u);
        info->acmd41_tries++;
    } while (r != 0 && CLOCK_CNT - t0 < 3u * CLOCK_HZ);
    info->r1_acmd41 = (uint8_t)r;
    info->acmd41_ms = (CLOCK_CNT - t0) / CLOCK_PER_MS;
    if (r != 0) { deselect(); return 2; }

    if (sd_cmd(58u, 0, 0x01u) != 0) { deselect(); return 3; }
    for (uint32_t i = 0; i < 4u; i++) info->ocr = (info->ocr << 8) | spi_xfer(0xFFu);
    block_addr = v2 && (info->ocr & 0x40000000u);
    info->block_addr = (uint8_t)block_addr;

    SPI_DIV = 0;   // CLOCK_HZ / 2: 18 MHz (SPI mode allows 25)
#ifndef SD_NO_HIGH_SPEED
    // SWITCH_FUNC (CMD6), mode 1, function group 1 (access mode) to 1:
    // High Speed, up to 50 MHz. The 64-byte status says which function the
    // group now has (bits 379:376, the low nibble of byte 16). Then the SPI
    // runs at the CPU clock (SPI_DIV_HS, 36 MHz, MISO sampled mid-cycle as
    // the card now changes it after the rising edge; ignored by bitstreams
    // without it, which stay at 18 MHz). Cards from SD 1.10 on have CMD6.
    uint8_t sw[64];
    if (sd_cmd(6u, 0x80FFFFF1u, 0x01u) == 0 && sd_read_data(sw, 64u) && (sw[16] & 0x0Fu) == 1u) {
        info->high_speed = 1;
        deselect();   // 8 clocks: the switch takes effect after the status block
        SPI_CTRL = SPI_CS_SD;
        SPI_DIV = SPI_DIV_HS;
    }
#endif
    uint8_t csd[16];
    if (sd_cmd(9u, 0, 0x01u) == 0 && sd_read_data(csd, 16u) && (csd[0] >> 6) == 1u) {
        uint32_t c_size = ((uint32_t)(csd[7] & 0x3Fu) << 16) | ((uint32_t)csd[8] << 8) | csd[9];
        info->sectors = (c_size + 1u) * 1024u;   // (C_SIZE + 1) * 512 KB
    }
    deselect();
    return 0;
}

int sd_read(uint32_t lba, uint8_t *buf, uint32_t count) {
    // READ_MULTIPLE_BLOCK: the card streams the sectors (each after its
    // access latency, which CMD17 would pay again per sector). The stream
    // stays open for a following read of the next sector (see stream_open).
    if (stream_open && lba != stream_next) sd_stop();
    SPI_CTRL = SPI_CS_SD;
    if (!stream_open) {
        if (sd_cmd(18u, block_addr ? lba : lba * 512u, 0x01u) != 0) {
            deselect();
            return 1;
        }
        stream_open = 1;
    }
    for (uint32_t k = 0; k < count; k++, buf += 512) {
        if (!sd_read_data(buf, 512u)) {
            sd_stop();
            return 1;
        }
    }
    stream_next = lba + count;
    return 0;
}

// Waits until the card stops signalling busy (MISO low), up to 500 ms.
static int sd_wait_ready(void) {
    uint32_t t0 = CLOCK_CNT;
    while (spi_xfer(0xFFu) != 0xFFu)
        if (CLOCK_CNT - t0 > CLOCK_HZ / 2u) return 0;
    return 1;
}

// Sends one data block with its start token and waits for the card to
// program it (CS low). Returns 1 if the card accepted it.
static int sd_write_data(const uint8_t *buf, uint32_t token) {
    if (!sd_wait_ready()) return 0;
    spi_xfer(token);
    for (uint32_t i = 0; i < 512u; i++) spi_xfer(buf[i]);
    spi_xfer(0xFFu);   // CRC (not checked in SPI mode)
    spi_xfer(0xFFu);
    uint32_t resp = spi_xfer(0xFFu) & 0x1Fu;   // data response: 0x05 accepted
    return resp == 0x05u && sd_wait_ready();
}

int sd_write(uint32_t lba, const uint8_t *buf, uint32_t count) {
    sd_stop();
    uint32_t addr = block_addr ? lba : lba * 512u;
    SPI_CTRL = SPI_CS_SD;
    int ok;
    if (count == 1u) {
        ok = sd_cmd(24u, addr, 0x01u) == 0 && sd_write_data(buf, 0xFEu);
    } else {
        // WRITE_MULTIPLE_BLOCK: blocks with token 0xFC, then the stop token
        // 0xFD, after which the card is busy until it is done.
        ok = sd_cmd(25u, addr, 0x01u) == 0;
        for (uint32_t k = 0; ok && k < count; k++, buf += 512) ok = sd_write_data(buf, 0xFCu);
        sd_wait_ready();
        spi_xfer(0xFDu);
        spi_xfer(0xFFu);
        ok = sd_wait_ready() && ok;
    }
    deselect();
    return ok ? 0 : 1;
}
