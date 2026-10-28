/* The m9b SoC: 64-by-32-bit division for the ports' fixed-point
 * libraries (Descent's maths/fixc.c: fixdiv, fixmuldiv, fixdivquadlong;
 * System Shock's FIX/Source/fix.c: fix_div and friends).
 *
 * The C versions divide long longs (libgcc's __divdi3, a few hundred
 * cycles on RV32) or, for fixdivquadlong, one bit per iteration. The
 * quotients always fit in 32 bits (the callers check or it's a fix), so
 * this does the division in two 16-bit digits with the hardware's 32-bit
 * divide (Hacker's Delight, divlu), about 100 cycles here. */
#ifndef M9B_DIV_H
#define M9B_DIV_H

#include <stdint.h>

/* (u1:u0) / v, unsigned; the quotient must fit in 32 bits (u1 < v),
 * else it saturates to 0xffffffff. */
static inline uint32_t m9b_divlu(uint32_t u1, uint32_t u0, uint32_t v)
{
	const uint32_t b = 65536;
	uint32_t un1, un0, vn1, vn0, q1, q0, un32, un21, un10, rhat;
	int s;

	if (u1 >= v)
		return 0xffffffffu;
	s = __builtin_clz(v);
	v <<= s;
	vn1 = v >> 16;
	vn0 = v & 0xffff;
	un32 = s ? (u1 << s) | (u0 >> (32 - s)) : u1;
	un10 = u0 << s;
	un1 = un10 >> 16;
	un0 = un10 & 0xffff;

	q1 = un32 / vn1;
	rhat = un32 - q1 * vn1;
	while (q1 >= b || q1 * vn0 > b * rhat + un1) {
		q1--;
		rhat += vn1;
		if (rhat >= b)
			break;
	}
	un21 = un32 * b + un1 - q1 * v;

	q0 = un21 / vn1;
	rhat = un21 - q0 * vn1;
	while (q0 >= b || q0 * vn0 > b * rhat + un0) {
		q0--;
		rhat += vn1;
		if (rhat >= b)
			break;
	}
	return q1 * b + q0;
}

/* n / d, signed, truncating like C; the quotient must fit in 32 bits
 * (it saturates otherwise). */
static inline int32_t m9b_div64_32(int64_t n, int32_t d)
{
	int neg = (n < 0) ^ (d < 0);
	uint64_t un = n < 0 ? -(uint64_t)n : (uint64_t)n;
	uint32_t ud = d < 0 ? -(uint32_t)d : (uint32_t)d;
	uint32_t q = m9b_divlu((uint32_t)(un >> 32), (uint32_t)un, ud);
	if (q > 0x7fffffffu)
		q = neg ? 0x80000000u : 0x7fffffffu;
	return neg ? -(int32_t)q : (int32_t)q;
}

/* n / d exactly, as int64_t division: the hardware path when the quotient
 * fits in 32 bits, else (and for d == 0) libgcc's. */
#ifdef M9B_DIV_STATS
extern uint32_t m9b_div_fast, m9b_div_lu, m9b_div_slow;
#define M9B_DIV_COUNT(c) ((c)++)
#else
#define M9B_DIV_COUNT(c) ((void)0)
#endif
static inline int64_t m9b_sdiv64(int64_t n, int32_t d)
{
	if (d != 0) {
		int neg = (n < 0) ^ (d < 0);
		uint64_t un = n < 0 ? -(uint64_t)n : (uint64_t)n;
		uint32_t ud = d < 0 ? -(uint32_t)d : (uint32_t)d;
		if ((uint32_t)(un >> 32) < ud) {   /* the quotient fits in 32 bits */
			uint32_t q;
			if ((un >> 32) == 0) { M9B_DIV_COUNT(m9b_div_fast); q = (uint32_t)un / ud; }   /* one hardware divide */
			else { M9B_DIV_COUNT(m9b_div_lu); q = m9b_divlu((uint32_t)(un >> 32), (uint32_t)un, ud); }
			return neg ? -(int64_t)q : (int64_t)q;
		}
	}
	M9B_DIV_COUNT(m9b_div_slow);
	return n / d;
}

#endif
