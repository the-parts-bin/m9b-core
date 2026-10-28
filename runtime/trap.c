// Trap handler (entered through trap_entry.S): emulates misaligned loads
// and stores, which the CPU doesn't do in hardware (picolibc's string
// functions and Doom's WAD structure accesses assume they work); anything
// else is reported and stops the program.
#include <stdint.h>
#include <stdio.h>
#include "m9b_map.h"

uint32_t misaligned_traps;   // count, for the frame-rate report

// PC-sampling profiler: the vertical-blank interrupt (60 Hz) records where
// the program was, in 16-byte buckets over the code (see prof_report()).
#define IRQ_PENDING (*(volatile uint32_t*)(M9B_CTRL + 0x4u))
#define PROF_BASE   M9B_PSRAM_BASE   // where the image starts (m9b.ld)
#ifndef PROF_SIZE
#define PROF_SIZE   0x00080000u   // the code's size, at most (-DPROF_SIZE=... for bigger programs)
#endif
uint16_t prof_hist[PROF_SIZE / 16u];
uint32_t prof_samples, prof_outside;

#ifdef M9B_PROFILE
// Where the program was at the last vertical blank (pc, ra), for a stall
// report (a program's vblank_flip may print them when it shows nothing).
uint32_t m9b_irq_pc, m9b_irq_ra;

// Where the emulated misaligned accesses are (the PC sampler can't see
// them: interrupts are off in here): counts by PC, 64 places at most (a
// new one replaces the least counted). prof_report lists them ("misal").
#define MIS_N 64u
static uint32_t mis_pc[MIS_N], mis_count[MIS_N];

static void note_misaligned(uint32_t pc) {
    uint32_t least = 0;
    for (uint32_t i = 0; i < MIS_N; i++) {
        if (mis_pc[i] == pc) { mis_count[i]++; return; }
        if (mis_count[i] < mis_count[least]) least = i;
    }
    mis_pc[least] = pc;
    mis_count[least] = 1;
}
#endif

#ifdef M9B_PROFILE
// One PC sample (at each vertical blank; -DPROF_ON_AUDIO: at each audio
// half instead, 187.5 per second and not tied to the display's timing,
// which a game's frame loop can be).
static void prof_sample(uint32_t epc, const uint32_t *regs) {
#ifdef PROF_MEMCPY_CALLERS   // =memcpy's size: a sample in memcpy counts at its caller (a leaf: ra holds it)
    { extern char memcpy[]; if (epc - (uint32_t)(uintptr_t)memcpy < (PROF_MEMCPY_CALLERS)) epc = regs[1] - 4u; }
#endif
    uint32_t off = epc - PROF_BASE;
    if (off < PROF_SIZE) { if (prof_hist[off / 16u] != 0xFFFFu) prof_hist[off / 16u]++; }
    else prof_outside++;
    prof_samples++;
}
#endif

void trap_handler(uint32_t *regs) {
    uint32_t cause, epc, addr;
    asm volatile("csrr %0, mcause" : "=r"(cause));
    asm volatile("csrr %0, mepc" : "=r"(epc));
    if (cause & 0x80000000u) {                      // interrupt: vblank, audio halves
        uint32_t pending = IRQ_PENDING;
        IRQ_PENDING = pending;
        extern void sound_irq(uint32_t pending);   // sound_m9b.c
        sound_irq(pending);
#if defined(M9B_PROFILE) && defined(PROF_ON_AUDIO)
        if (pending & 6u) prof_sample(epc, regs);
#endif
        if (!(pending & 1u)) return;
        extern void vblank_flip(void);   // doomgeneric_m9b.c
#ifdef M9B_PROFILE
        m9b_irq_pc = epc;
        m9b_irq_ra = regs[1];
#endif
        vblank_flip();
#if defined(M9B_PROFILE) && !defined(PROF_ON_AUDIO)
        prof_sample(epc, regs);
#endif
        return;
    }
    asm volatile("csrr %0, mtval" : "=r"(addr));
    uint32_t insn = *(volatile uint32_t *)epc;   // no compressed instructions (rv32im)
    uint32_t op = insn & 0x7Fu, f3 = (insn >> 12) & 7u;
    uint32_t rd = (insn >> 7) & 31u, rs2 = (insn >> 20) & 31u;
    volatile uint8_t *p = (volatile uint8_t *)(uintptr_t)addr;

    if (cause == 4u && op == 0x03u && (f3 == 1u || f3 == 2u || f3 == 5u)) {        // lh, lw, lhu
        uint32_t v = p[0] | (uint32_t)p[1] << 8;
        if (f3 == 2u) v |= (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
        else if (f3 == 1u) v = (uint32_t)(int32_t)(int16_t)v;
        if (rd) regs[rd] = v;
    } else if (cause == 6u && op == 0x23u && (f3 == 1u || f3 == 2u)) {             // sh, sw
        uint32_t v = regs[rs2];
        p[0] = (uint8_t)v;
        p[1] = (uint8_t)(v >> 8);
        if (f3 == 2u) {
            p[2] = (uint8_t)(v >> 16);
            p[3] = (uint8_t)(v >> 24);
        }
    } else {
        printf("\n*** trap: mcause %08lx mepc %08lx mtval %08lx insn %08lx\n",
               (unsigned long)cause, (unsigned long)epc, (unsigned long)addr, (unsigned long)insn);
        for (;;) {
        }
    }
    misaligned_traps++;
#ifdef M9B_PROFILE
    note_misaligned(epc);
#endif
    asm volatile("csrw mepc, %0" :: "r"(epc + 4u));
}

// Prints the 40 busiest buckets ("prof <address> <samples>"), for
// tools/profile.py to map to functions, and clears the histogram.
void prof_report(void) {
    printf("prof begin %lu samples (%lu outside the code)\n",
           (unsigned long)prof_samples, (unsigned long)prof_outside);
    for (int k = 0; k < 40; k++) {
        uint32_t best = 0, bi = 0;
        for (uint32_t i = 0; i < PROF_SIZE / 16u; i++)
            if (prof_hist[i] > best) { best = prof_hist[i]; bi = i; }
        if (!best) break;
        printf("prof %08lx %lu\n", (unsigned long)(PROF_BASE + bi * 16u), (unsigned long)best);
        prof_hist[bi] = 0;
    }
    for (uint32_t i = 0; i < PROF_SIZE / 16u; i++) prof_hist[i] = 0;
#ifdef M9B_PROFILE
    for (uint32_t i = 0; i < MIS_N; i++)
        if (mis_count[i]) printf("misal %08lx %lu\n", (unsigned long)mis_pc[i], (unsigned long)mis_count[i]);
    for (uint32_t i = 0; i < MIS_N; i++) mis_pc[i] = mis_count[i] = 0;
#endif
    printf("prof end\n");
    prof_samples = prof_outside = 0;
}
