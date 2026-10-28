// memcpy / memmove / memset without misaligned accesses (picolibc's assume
// the CPU handles them; ours traps, see trap.c): words when source and
// destination are equally aligned, bytes otherwise. Linked before libc.
//
// Whole 64-byte lines of PSRAM that are about to be overwritten are first
// allocated with cbo.zero (Zicboz): the data cache fills the line with
// zeros instead of reading it from PSRAM. memset(0) then needs no stores at
// all for them. Only within PSRAM (cbo.zero faults on I/O), only for
// complete lines, and in memcpy only when the buffers don't overlap
// (memmove's forward copies come through here, and zeroing the destination
// line could wipe source bytes not read yet). An interrupt between the
// cbo.zero and the stores is harmless: the whole line is written anyway.
// Build with -DNO_CBOZ for the plain version.
#include <stddef.h>
#include <stdint.h>

#include "m9b_map.h"

#define LINE 64u

static inline int in_psram(const void *p, size_t n) {
    uintptr_t a = (uintptr_t)p;
    return a >= M9B_PSRAM_BASE && a + n <= M9B_PSRAM_BASE + M9B_PSRAM_SIZE && a + n >= a;
}

static inline void cbo_zero(void *p) {
    asm volatile(".insn i 0x0F, 2, x0, %0, 4" :: "r"(p) : "memory");   // cbo.zero (p)
}

void *memcpy(void *restrict dst, const void *restrict src, size_t n) {
    uint8_t *d = dst;
    const uint8_t *s = src;
    if ((((uintptr_t)d ^ (uintptr_t)s) & 3u) == 0) {
        while (n && ((uintptr_t)d & 3u)) { *d++ = *s++; n--; }
        uint32_t *dw = (uint32_t *)d;
        const uint32_t *sw = (const uint32_t *)s;
#ifndef NO_CBOZ
        if (n >= 2u * LINE && in_psram(dw, n) &&
            ((uintptr_t)dw + n <= (uintptr_t)sw || (uintptr_t)sw + n <= (uintptr_t)dw)) {
            for (; (uintptr_t)dw & (LINE - 1u); n -= 4) *dw++ = *sw++;
            for (; n >= LINE; n -= LINE, dw += 16, sw += 16) {
                cbo_zero(dw);
                uint32_t a = sw[0], b = sw[1], c = sw[2], e = sw[3];
                dw[0] = a; dw[1] = b; dw[2] = c; dw[3] = e;
                a = sw[4]; b = sw[5]; c = sw[6]; e = sw[7];
                dw[4] = a; dw[5] = b; dw[6] = c; dw[7] = e;
                a = sw[8]; b = sw[9]; c = sw[10]; e = sw[11];
                dw[8] = a; dw[9] = b; dw[10] = c; dw[11] = e;
                a = sw[12]; b = sw[13]; c = sw[14]; e = sw[15];
                dw[12] = a; dw[13] = b; dw[14] = c; dw[15] = e;
            }
        }
#endif
        for (; n >= 16; n -= 16, dw += 4, sw += 4) {
            uint32_t a = sw[0], b = sw[1], c = sw[2], e = sw[3];
            dw[0] = a; dw[1] = b; dw[2] = c; dw[3] = e;
        }
        for (; n >= 4; n -= 4) *dw++ = *sw++;
        d = (uint8_t *)dw;
        s = (const uint8_t *)sw;
    }
    while (n--) *d++ = *s++;
    return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
    uint8_t *d = dst;
    const uint8_t *s = src;
    if (d <= s || d >= s + n) return memcpy(dst, src, n);
    d += n;
    s += n;
    while (n--) *--d = *--s;
    return dst;
}

void *memset(void *dst, int c, size_t n) {
    uint8_t *d = dst;
    while (n && ((uintptr_t)d & 3u)) { *d++ = (uint8_t)c; n--; }
    uint32_t w = (uint8_t)c * 0x01010101u;
    uint32_t *dw = (uint32_t *)d;
#ifndef NO_CBOZ
    if (n >= 2u * LINE && in_psram(dw, n)) {
        for (; (uintptr_t)dw & (LINE - 1u); n -= 4) *dw++ = w;
        if (w == 0) {
            for (; n >= LINE; n -= LINE, dw += 16) cbo_zero(dw);
        } else {
            for (; n >= LINE; n -= LINE, dw += 16) {
                cbo_zero(dw);
                dw[0] = w; dw[1] = w; dw[2] = w; dw[3] = w;
                dw[4] = w; dw[5] = w; dw[6] = w; dw[7] = w;
                dw[8] = w; dw[9] = w; dw[10] = w; dw[11] = w;
                dw[12] = w; dw[13] = w; dw[14] = w; dw[15] = w;
            }
        }
    }
#endif
    for (; n >= 4; n -= 4) *dw++ = w;
    d = (uint8_t *)dw;
    while (n--) *d++ = (uint8_t)c;
    return dst;
}
