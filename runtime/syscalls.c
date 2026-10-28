// System calls for picolibc: the console on the UART, and files on the SD
// card through FatFs (built writable: savegames).
#include <errno.h>
#include "m9b_map.h"
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "ff.h"

#define UART_DATA   (*(volatile uint32_t*)M9B_UART)
#define UART_STATUS (*(volatile uint32_t*)(M9B_UART + 0x4u))
#define UART_TX_BUSY (1u << 0)

static void uart_putc(char c) {
    while (UART_STATUS & UART_TX_BUSY) {
    }
    UART_DATA = (uint8_t)c;
}

static int console_put(char c, FILE *f) {
    (void)f;
    if (c == '\n') uart_putc('\r');
    uart_putc(c);
    return (uint8_t)c;
}

static FILE console = FDEV_SETUP_STREAM(console_put, NULL, NULL, _FDEV_SETUP_WRITE);
FILE *const stdout = &console;
FILE *const stderr = &console;

// -------------------------------------------------------------------------
// Files: fds 0..2 are the console, 3.. index a small table of FatFs files.
// -------------------------------------------------------------------------
#define FD_FIRST 3
#ifndef MAX_FILES
#define MAX_FILES 8   // (-DMAX_FILES=... for programs that keep more open)
#endif

static FATFS fs;
static int mounted;
static FIL files[MAX_FILES];
static uint8_t in_use[MAX_FILES];

static FIL *fd_file(int fd) {
    fd -= FD_FIRST;
    if (fd < 0 || fd >= MAX_FILES || !in_use[fd]) return NULL;
    return &files[fd];
}

static int mount(void) {
    if (!mounted) {
        if (f_mount(&fs, "", 1) != FR_OK) { errno = EIO; return -1; }
        mounted = 1;
    }
    return 0;
}

// For callers that use FatFs directly beside these calls (directory
// listings, f_stat): the same mount.
int m9b_fs_mount(void) { return mount(); }

static int fr_errno(FRESULT fr) {
    switch (fr) {
    case FR_NO_FILE: case FR_NO_PATH: return ENOENT;
    case FR_EXIST: return EEXIST;
    case FR_DENIED: case FR_WRITE_PROTECTED: return EACCES;
    case FR_INVALID_NAME: return EINVAL;
    default: return EIO;
    }
}

int open(const char *path, int flags, ...) {
    if (mount()) return -1;
    BYTE mode = (flags & O_ACCMODE) == O_RDONLY ? FA_READ
              : (flags & O_ACCMODE) == O_WRONLY ? FA_WRITE : FA_READ | FA_WRITE;
    if (flags & O_CREAT)
        mode |= (flags & O_TRUNC) ? FA_CREATE_ALWAYS : (flags & O_EXCL) ? FA_CREATE_NEW : FA_OPEN_ALWAYS;
    else if (flags & O_TRUNC)
        mode |= FA_CREATE_ALWAYS;   // (only on an existing file in POSIX; close enough)
    for (int i = 0; i < MAX_FILES; i++) {
        if (in_use[i]) continue;
        FRESULT fr = f_open(&files[i], path, mode);
        if (fr == FR_OK && (flags & O_APPEND)) fr = f_lseek(&files[i], f_size(&files[i]));
        if (fr != FR_OK) {
            errno = fr_errno(fr);
            return -1;
        }
        in_use[i] = 1;
        return FD_FIRST + i;
    }
    errno = EMFILE;
    return -1;
}

uint32_t m9b_read_bytes, m9b_read_cycles;   // for the frame-rate report

ssize_t read(int fd, void *buf, size_t n) {
    FIL *f = fd_file(fd);
    if (!f) { errno = EBADF; return -1; }
    UINT got;
    uint32_t t0 = *(volatile uint32_t *)(M9B_TIMING + 0xCu);   // clock counter
    FRESULT fr = f_read(f, buf, n, &got);
    m9b_read_cycles += *(volatile uint32_t *)(M9B_TIMING + 0xCu) - t0;
    if (fr != FR_OK) { errno = EIO; return -1; }
    m9b_read_bytes += got;
    return got;
}

// fread: picolibc's (built without __FAST_BUFIO) takes a byte at a time
// through getc and the stream's locked get function; libstdc++'s file
// streams read through it. This is picolibc's fast path: what is buffered
// is copied, small reads refill the buffer, large ones go straight to
// read(). (Single-threaded, and no files in interrupts: no locks.)
#include <stdio-bufio.h>
int __bufio_fill_locked(FILE *f);
int __bufio_setdir_locked(FILE *f, uint8_t dir);

size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream) {
    uint8_t *cp = ptr;
    size_t bytes = size * nmemb;
    if (!(stream->flags & __SRD) || !bytes) return 0;
    if (!(stream->flags & __SBUF)) {
        for (; bytes; bytes--) {
            int c = getc(stream);
            if (c == EOF) break;
            *cp++ = (uint8_t)c;
        }
        return (cp - (uint8_t *)ptr) / size;
    }
    struct __file_bufio *bf = (struct __file_bufio *)stream;
    if (__bufio_setdir_locked(stream, __SRD) < 0) return 0;
    if (stream->unget) {
        *cp++ = (uint8_t)(stream->unget - 1);
        stream->unget = 0;
        bytes--;
    }
    while (bytes) {
        size_t n = bf->len - bf->off;
        if (n) {
            if (n > bytes) n = bytes;
            memcpy(cp, bf->buf + bf->off, n);
            bf->off += n;
        } else if (bytes < (size_t)bf->size) {
            int r = __bufio_fill_locked(stream);
            if (r) {
                stream->flags |= r == _FDEV_ERR ? __SERR : __SEOF;
                break;
            }
            continue;
        } else {
            bf->len = bf->off = 0;
            ssize_t got = bf->bflags & __BFPTR ? bf->read_ptr((void *)bf->ptr, cp, bytes)
                                               : bf->read_int((int)(intptr_t)bf->ptr, cp, bytes);
            if (got <= 0) {
                stream->flags |= got < 0 ? __SERR : __SEOF;
                break;
            }
            n = got;
            bf->pos += got;
        }
        cp += n;
        bytes -= n;
    }
    return (cp - (uint8_t *)ptr) / size;
}

ssize_t write(int fd, const void *buf, size_t n) {
    if (fd == 1 || fd == 2) {
        const char *p = buf;
        for (size_t i = 0; i < n; i++) console_put(p[i], NULL);
        return n;
    }
    FIL *f = fd_file(fd);
    if (!f) { errno = EBADF; return -1; }
    UINT done;
    FRESULT fr = f_write(f, buf, n, &done);
    if (fr != FR_OK) { errno = fr_errno(fr); return -1; }
    return done;
}

off_t lseek(int fd, off_t off, int whence) {
    FIL *f = fd_file(fd);
    if (!f) { errno = EBADF; return -1; }
    FSIZE_t pos = whence == SEEK_SET ? (FSIZE_t)off
                : whence == SEEK_CUR ? f_tell(f) + off
                : f_size(f) + off;
    if (f_lseek(f, pos) != FR_OK) { errno = EINVAL; return -1; }
    return (off_t)f_tell(f);
}

int ftruncate(int fd, off_t len) {
    FIL *f = fd_file(fd);
    if (!f) { errno = EBADF; return -1; }
    FSIZE_t pos = f_tell(f);
    FRESULT fr = f_lseek(f, (FSIZE_t)len);   // FatFs truncates at the file pointer
    if (fr == FR_OK) fr = f_truncate(f);
    if (fr == FR_OK) fr = f_lseek(f, pos);
    if (fr != FR_OK) { errno = fr_errno(fr); return -1; }
    return 0;
}

int close(int fd) {
    FIL *f = fd_file(fd);
    if (!f) { errno = EBADF; return -1; }
    FRESULT fr = f_close(f);   // writes out what is still buffered
    in_use[fd - FD_FIRST] = 0;
    if (fr != FR_OK) { errno = fr_errno(fr); return -1; }
    return 0;
}

int unlink(const char *path) {
    if (mount()) return -1;
    FRESULT fr = f_unlink(path);
    if (fr != FR_OK) { errno = fr_errno(fr); return -1; }
    return 0;
}

int rename(const char *a, const char *b) {
    if (mount()) return -1;
    FRESULT fr = f_rename(a, b);   // fails if b exists (Doom removes it first)
    if (fr != FR_OK) { errno = fr_errno(fr); return -1; }
    return 0;
}

int mkdir(const char *path, mode_t mode) {
    (void)mode;
    if (mount()) return -1;
    char p[128];
    size_t n = strlen(path);
    if (n >= sizeof(p)) { errno = ENAMETOOLONG; return -1; }
    memcpy(p, path, n + 1);
    while (n > 1 && p[n - 1] == '/') p[--n] = 0;   // FatFs takes no trailing '/'
    FRESULT fr = f_mkdir(p);
    if (fr != FR_OK) { errno = fr_errno(fr); return -1; }
    return 0;
}

void _exit(int code) {
    printf("\n[exit %d]\n", code);
    for (;;) {
    }
}
