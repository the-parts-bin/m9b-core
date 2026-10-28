// The CPU clock, which CLOCK_CNT (M9B_TIMING + 0xC) counts and the UART and SPI
// dividers divide: 36 MHz (system_clk / 2, see rtl/top.v). Everything that
// times, waits or picks a divider uses these.
#ifndef CLOCK_H
#define CLOCK_H

#define CLOCK_HZ      36000000u
#define CLOCK_PER_MS  (CLOCK_HZ / 1000u)
#define CLOCK_PER_US  (CLOCK_HZ / 1000000u)

// UART DIV for a baud rate (bit period in clock cycles, rounded).
#define UART_DIV_FOR(baud) ((CLOCK_HZ + (baud) / 2u) / (baud))

// SPI_DIV for an SCLK frequency: SCLK = CLOCK_HZ / (2 * (div + 1)), the
// fastest not above hz.
#define SPI_DIV_FOR(hz) ((CLOCK_HZ + 2u * (hz) - 1u) / (2u * (hz)) - 1u)

#endif
