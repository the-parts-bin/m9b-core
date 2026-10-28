// FatFs disk I/O glue: drive 0 is the SD card. Read-only unless FatFs is
// built with FF_FS_READONLY 0 (tools/sdput).
#include "fatfs/ff.h"
#include "fatfs/diskio.h"
#include "sd.h"

static DSTATUS status = STA_NOINIT;

DSTATUS disk_status(BYTE pdrv) {
    return pdrv ? STA_NOINIT : status;
}

DSTATUS disk_initialize(BYTE pdrv) {
    if (pdrv) return STA_NOINIT;
    if (status & STA_NOINIT) {
        sd_info_t info;
        if (sd_init(&info) == 0) status = FF_FS_READONLY ? STA_PROTECT : 0;
    }
    return status;
}

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count) {
    if (pdrv || (status & STA_NOINIT)) return RES_NOTRDY;
    return sd_read((uint32_t)sector, buff, count) ? RES_ERROR : RES_OK;
}

#if !FF_FS_READONLY
DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count) {
    if (pdrv || (status & STA_NOINIT)) return RES_NOTRDY;
    return sd_write((uint32_t)sector, buff, count) ? RES_ERROR : RES_OK;
}
#endif

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff) {
    (void)buff;
    if (pdrv || (status & STA_NOINIT)) return RES_NOTRDY;
    return cmd == CTRL_SYNC ? RES_OK : RES_PARERR;
}
