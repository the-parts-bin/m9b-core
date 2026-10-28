# m9b core: a VexiiRiscv SoC for the Tang Nano 9K

A RISC-V system on the Tang Nano 9K (Gowin GW1NR-LV9QN88PC6/I5) with
cached access to the on-package 8 MB HyperRAM and HDMI video and audio
driven by DMA.

- **CPU:** VexiiRiscv (RV32IM + Zba + Zicbom + Zicbop + Zicboz, radix-4 divider) at 36 MHz, on the PSRAM
  controller's clock tree (half its clock). Its L1 caches use
  64-byte lines on 64-bit Wishbone buses:
  - instruction L1: 8 KB, direct-mapped
  - data L1: 16 KB, 2-way set-associative, write-back (stores write whole
    words, see Notes: the BSRAM byte enables misbehave)
- **User flash:** the GW1NR-9's 76 KB on-chip flash at `0x00000000`,
  cached and read-only. The firmware runs from it in place. Its writable
  data and stack are in the top 128 KB of PSRAM, so programs load from
  the start of PSRAM (below).
- **HyperRAM:** both 4 MB dies, interleaved word by word into 8 MB. It is
  cached at `0x800000`. The same controller also DMAs video lines and
  audio samples into an on-chip buffer (`hr_ram`).
- **Video:** 720×480 at 59.94 Hz over HDMI. The picture is built line by line
  from a per-line table: each visible line is 16 bpp RGB565, 8 bpp
  paletted (720 pixels, or 2× from a window), or blank, with a per-line
  horizontal scroll offset. Text is drawn in software (the hardware text
  mode was removed to free logic and a block RAM).
- **Audio:** 48 kHz 16-bit stereo, sent in the HDMI data islands and played
  from two 1 KB halves that the CPU refills on interrupt.
- **Interrupts:** vertical blank, and one per audio half finished.
- **SPI:** one master for the on-board 4 MB SPI flash (P25Q32U) and the
  SD card slot.
- **USB host:** two low-speed ports, each for a keyboard, mouse or gamepad
  (nand2mario's `usb_hid_host`, with fixes, one engine for both ports). Tested with a keyboard and a
  mouse at the same time.
- **Serial loader:** `tools/run.py` uploads a program into PSRAM and runs
  it, then acts as a terminal (see Serial loader).

![System diagram: clock domains, units, caches and buffers](doc/system.svg)

Dashed regions are clock domains; yellow boxes are block RAM or PSRAM; red
boxes are on the board, outside the chip. The bridge and the transfer RAM
(`hr_ram`) connect domains: the bridge between the CPU and the controller,
which share a clock tree, the transfer RAM between the controller and the
video side, which don't. (`doc/system.svg` is plain SVG, edited by hand.)

## Sources

The SoC's own parts were written for m9b: the PSRAM controller (grown from
an earlier test design of the author's), the bridge, the video and audio
engine, the SPI master, the UART, the user flash reader, the boot
firmware, the SD driver, the runtime and the tools. It also uses, or was
built from:

| Part | Upstream | Version | Here |
|---|---|---|---|
| CPU | [SpinalHDL/VexiiRiscv](https://github.com/SpinalHDL/VexiiRiscv) (Charles Papon) | `dev` at `42268af`, plus m9b's options from the fork [the-parts-bin/m9b-VexiiRiscv](https://github.com/the-parts-bin/m9b-VexiiRiscv), branch `m9b` at `b4c9beb` | `rtl/VexiiRiscv.v`, generated (Notes) |
| HDMI encoder | [hdl-util/hdmi](https://github.com/hdl-util/hdmi) (Sameer Puri) | | `rtl/hdmi/` |
| USB host | [nand2mario/usb_hid_host](https://github.com/nand2mario/usb_hid_host) (based on hi631's work) | `678b013` | `rtl/usb_hid_host*` |
| FAT filesystem | [FatFs](https://elm-chan.org/fsw/ff/) (ChaN) | R0.16 | `firmware/fatfs/` |
| Boot screen font | Pixel Operator (Jayvee Enaguas) | | `firmware/fonts/` |
| Programs' linker script | [picolibc](https://github.com/picolibc/picolibc)'s `picolibcpp.ld` | 1.8.10 | `runtime/m9b.ld` |
| Music renderer | [Wohlstand/libADLMIDI](https://github.com/Wohlstand/libADLMIDI) | `ef98fab` (fetched by `tools/midirender/build.sh`) | `tools/midirender/` |
| PLLs, block RAM wrappers | Gowin's IP generator | | `rtl/gowin_*/` |

The first versions of the design ran [FemtoRV32](https://github.com/BrunoLevy/learn-fpga)
(Bruno Levy) with its UART, then LiteX's VexRiscv; both are gone (they are
in the history). What changed in the third-party parts is under Changes to
the third-party parts, below.

## Files

| File | Contents |
|---|---|
| `rtl/top.v` | clocks, resets, HDMI, test-pattern option (`HDMI_TEST_PATTERN`) |
| `rtl/soc.v` | CPU, memory buses, I/O registers, clock-domain crossings |
| `rtl/hyperram.sv` | PSRAM controller: cache-line transfers and DMA |
| `rtl/psram_bridge.v` | 64-byte line buffers between the data L1 and the controller |
| `rtl/video_engine.v` | scanout (line table, the three pixel modes), audio playback, DMA requests, IRQ events |
| `rtl/vram.v`, `rtl/gen_vram_init.py` | video RAM (palette, line table) and its initial contents (`vram_init0.hex`, the old text mode's 8×16 font, is no longer used) |
| `rtl/ufm.v` | user flash (FLASH608K) read controller, one 32-bit word per 4 cycles |
| `rtl/spi.v` | SPI master (mode 0, 8 or 32 bits per transfer, programmable clock) |
| `rtl/Ram_1w_1rs.v` | unused: SDPB-based RAM for SpinalHDL's black boxes (see Notes) |
| `rtl/gpu.sv` | the old 1280-wide test pattern, used only with `HDMI_TEST_PATTERN` |
| `rtl/hdmi/` | HDMI 1.4 encoder (Sameer Puri's core, MIT or Apache 2.0, `LICENSE-*`; one clock per pixel, pipelined TMDS encoder) |
| `rtl/VexiiRiscv.v` | the CPU, generated from VexiiRiscv (MIT, `VexiiRiscv.LICENSE`; see Notes) |
| `rtl/gowin_*/` | Gowin primitives' wrappers: the PLLs, `hr_ram`'s block RAM (`dpb_8k32_64.v`), the HDMI test pattern's RAMs (made with Gowin's IP generator; these `.v` files are the source now) |
| `rtl/uart.v` | UART: programmable bit period, 16-byte receive FIFO, reset string |
| `rtl/usb_port.v` | one USB port's registers, clock crossing and reset (two instances in `soc.v`; the host core serves both) |
| `rtl/usb_hid_host*.v`, `.hex`, `rtl/gen_usb_rom.py` | nand2mario's USB HID host (Apache 2.0, `usb_hid_host.LICENSE`), with the changes listed under USB host |
| `tools/run.py` | host side of the serial loader, and a terminal |
| `tools/usbdiag/` | USB diagnostics, run through the loader (see USB host) |
| `tools/sdput/` | writes files to the SD card through the board (see SD card) |
| `tools/gw_sh.sh` | runs the Gowin IDE's Tcl shell (`build.sh`, `tests/bsram_be`) |
| `tools/midirender/` | renders MIDI-type music (MID, XMI, HMP via MIDI) with libADLMIDI's OPL3 emulation, optionally with a game's own AIL timbre library (`-a`), and `finish.py` makes the 24 kHz mono WAV files the ports stream, at a common loudness (-18 LUFS, peaks at most -1 dBFS); used by the Descent, Ultima VII and System Shock music scripts (Doom's uses its libADLMIDI build), at a pinned libADLMIDI version so that renders repeat exactly |
| `tools/m9bctl.py` | drives a running program over the UART: screenshots (`shot OUT.png`) and keys (`keys ...`), for testing without watching the screen |
| `tools/prof.py` | maps a profile build's PC samples (from its UART log) to functions: `prof.py ELF LOG` |
| `firmware/` | `hello.c` (boot tests, benchmarks, start-up chime), `boot.c` (boot screen and SD program browser), `sd.c`, `diskio.c` + FatFs, `loader.c`; `gen_assets.py` makes `assets.h` (logo, palette, fonts) |
| `firmware/fonts/` | Pixel Operator regular and bold (Jayvee Enaguas, CC0 1.0, `PixelOperator-LICENSE.txt`): the boot screen's proportional 16 px font |
| `runtime/` | what the programs on the SD card link with: `syscalls.c` (picolibc's system calls: console on the UART, files on the SD card through FatFs), `trap_entry.S` and `trap.c` (interrupts, misaligned loads/stores emulated, the PC-sampling profiler), `string.c` (`memcpy`/`memmove`/`memset` without misaligned accesses, with `cbo.zero`), `m9b.ld` (the memory map, see Building). The game ports (in m9b-system) build them with their own sources |
| `sim/` | simulations (see below) |

## Clocks

| Clock | Frequency | Source | Used by |
|---|---|---|---|
| `hdmi_bit_clk` | 135 MHz | `pll_hdmi` (27 × 5) | TMDS serializers (OSER10 FCLK, DDR) |
| `pixel_clk` | 27 MHz | `hdmi_bit_clk` / 5 (CLKDIV) | HDMI encoder, video engine, `hr_ram` port A |
| `cpu_clk` | 36 MHz | `system_clk` / 2 (CLKDIV) | **CPU**, I/O (UART, SPI, USB registers, video RAM writes), user flash, the bridge's CPU side |
| `memory_clk` | 144 MHz | `pll_main` (27 × 16 / 3) | PSRAM I/O (OSER4/IDES4 FCLK) |
| `system_clk` | 72 MHz | `pll_main` CLKOUTD | PSRAM controller, bridge's controller side, `hr_ram` port B |
| `usb_clk` | 12 MHz | `pll_main` CLKOUTD3 (48 MHz) / 4 (CLKDIV) | USB HID host (needs exactly 12 MHz) |
| `ext_clk` | 27 MHz | oscillator | PLL references, heartbeat LED |

The pixel clock is the serializer clock divided down, so the OSER10s'
parallel and serial clocks are phase-aligned by construction. The two PLLs
have unrelated output phases, so everything between the pixel clock and
`pll_main`'s clocks (CPU, controller) goes through synchronizers:

- configuration levels: two flops each
- audio pointer writes and IRQ events: toggles
- the DMA start and busy handshake (video engine and controller)
- video RAM: written on `cpu_clk`, read on `pixel_clk` (dual-clock BSRAM)

**The CPU and the controller are synchronous** (`cpu_clk` = `system_clk` /
2 through a CLKDIV, one clock group in `top.sdc`, so the paths between them
are timed, with one 72 MHz period each way). The bridge's line request and
ack cross with one flop each (`SYNC` / `LINE_SYNC` parameters) instead of
two-flop synchronizers; straight through, they reached deep logic (the
CPU's bus handshake, the controller's arbitration) in half a CPU cycle.
The bridge answers a refill's first beat in the cycle the ack arrives.

**Time base.** `CLOCK_CNT`, the UART's bit period and the SPI divider all
count CPU clock cycles (36 MHz). Software takes the numbers from
`firmware/clock.h` (`CLOCK_HZ`, `CLOCK_PER_MS`, `UART_DIV_FOR()`,
`SPI_DIV_FOR()`), and `tools/run.py` computes its dividers from the same
clock (115200 baud is 313, 921600 is 39; the reset value is 312).
`soc.v`'s `CPU_36MHZ = 0` goes back to a 27 MHz CPU clock (the earlier
design's).

`top.sdc` declares the groups (oscillator, `pll_main`'s PSRAM clocks, the
USB clocks, and `pll_hdmi`'s) as asynchronous. PSRAM ran at 162 MHz before
the USB clock needed a divisible PLL frequency.

**Timing.** At the last build (`place_option` 0, `route_option` 2,
`build.tcl`), `clk_cpu` reached 37.78 MHz against the 36 MHz needed and
`clk_sys` 79.66 MHz against 72 (`clk_pix` 56.4, `clk_usb` 58.7). Logic use
is 88% (7560/8640; CLS 4150/4320, 97%) and BSRAM 25/26: the device is
close to full and the margin thin, so check the timing summary after every
build. At this utilisation Fmax depends a lot on placement: `place_option`
1/2/3 give identical results, as do 0/4, so there are two placements to
choose from, and `route_option` 0, 1 and 2 differ by several MHz from
build to build, so try the others when one fails. The Gowin options
`-retiming` and `-replicate_resources` changed nothing. Meeting 36 MHz
took `--relaxed-shift` in VexiiRiscv, the one-flop crossings above, a
registered `init_ready` in `hyperram.sv` (its 14-bit compare fed the
arbitration every cycle), and a false path for the controller's reset to
the I/O serializers.

**How the CPU got here** (Doom's timedemo, `../doom`, is the benchmark;
times to the same tic, lower is better):

| Step | `clk_cpu` | Timedemo |
|---|---|---|
| 27 MHz CPU (`CPU_36MHZ = 0`) | | tic 2000 in 144.1 s |
| 36 MHz CPU (Zba, Zicbop) | 38.75 MHz | 110.9 s (1.30x); memory benchmarks +31-34% |
| + SPI at 18 MHz, the bridge's early first beat | | 108.5 s |
| 2-way data L1 with word writes, read acks from registers, SD High Speed, `cbo.zero` memset/memcpy | 36.83 MHz | tic 4250 in 194.93 s (21.8 fps), against 225.99 s with the direct-mapped data L1 |
| + 24-bit addresses (Memory map) and the unbuffered data L1 bus (`--lsu-l1-wishbone-unbuffered`: a miss one cycle shorter) | 37.86 MHz | 194.42 s (0.6%) |
| + radix-4 divider (`--div-radix 4`: a 32-bit divide in about 16 cycles instead of 32; +164 logic cells) | 37.78 MHz | 192.13 s (1.2%); System Shock +8% (7.4 fps against 6.9: its texture mapper divides per span) |

**Measured, not adopted:**
- Zbb: +566 logic cells, CLS 98%, `clk_cpu` 32-33 MHz and `clk_sys` 61-65
  MHz: doesn't fit.
- Without `--relaxed-branch` (branches resolved a stage earlier): the
  timedemo 1.0% faster, but `clk_cpu` 36.06 MHz (0.05 ns of slack) with
  place option 1 only, and with the unbuffered bus as well 31-33.5 MHz
  (the branch resolution path from execute to fetch).

| BSRAM user | Blocks |
|---|---|
| CPU | 18: data L1 8 (four 1024 × 32 arrays, two per way, written in whole words) + 2 tags; fetch L1 4 + 1 tags; branch predictor (BTB) 1 (36-bit entries, see Notes); register file 2 |
| video RAM | 2 (palette and line table; the text mode's font block is gone) |
| `hr_ram` | 4 |
| USB HID host's microcode ROM | 1: a pROM (`rtl/usb_hid_host_rom.v`, generated by `rtl/gen_usb_rom.py`) |

## Memory map

Addresses are 24 bits: the CPU is generated with a 24-bit physical width
(`--physical-width 24`), so its PCs, address registers, adders and cache
tags are 24 bits, and any access at or above 16 MB traps (access fault).
Software takes the map from `firmware/m9b_map.h` (all the ports build with
`-I core/firmware`); the linker scripts and the start-up code's stack
pointers repeat the numbers.

| Address | Device |
|---|---|
| `0x000000`–`0x012FFF` | user flash (76 KB, cached, read-only; writes are ignored) |
| `0x800000`–`0xFFFFFF` | HyperRAM (8 MB, cached): programs load from `0x800000` (up to 7.5 MB); the boot screen's framebuffer is at `0xF80000` and the firmware's data and stack at `0xFE0000`–`0xFFFFFF`, both free once a program runs |
| `0x410000` | UART DATA: write sends a byte; read returns `{tx_busy, rx_valid, rx_data[7:0]}` and takes the byte from the receive FIFO |
| `0x410004` | UART STATUS: bit 0 tx busy, bit 1 rx valid, bit 2 rx overrun (write 1 to clear) |
| `0x410008` | UART DIV: bit period in CPU clock cycles (reset 312 = 115200 baud; 39 = 921600, 24 = 1.5 M, 12 = 3 M) |
| `0x420000`–`0x4217FF` | video RAM (palette and line table from `0x800`; 32-bit word writes only) |
| `0x430000` | VIDEO_CTRL: bit 0 video enable |
| `0x430004` | IRQ_PENDING: bit 0 vblank, bit 1 audio half A done, bit 2 half B done, bit 3 USB report (write 1 to clear) |
| `0x430008` | IRQ_ENABLE (same bits) |
| `0x43000C` | AUDIO_CTRL: bit 0 audio enable |
| `0x430010` | AUDIO_PTR_A: PSRAM byte offset (256-byte aligned) of 1 KB of samples; a write DMAs it into half A (only bits 22:8 are kept) |
| `0x430014` | AUDIO_PTR_B: the same for half B |
| `0x430018` | VIDEO_HWIN: bits 9:0 first column, 25:16 end column of 2× lines (reset 40, 680) |
| `0x440000`–`0x44000C` | x_cnt, y_cnt, frame_cnt (pixel clock, read unsynchronized), CLOCK_CNT (CPU clock cycles, 36 MHz) |
| `0x450000` | SPI_DATA: write sends a byte (starts a transfer); read returns the last byte received |
| `0x450004` | SPI_CTRL: bit 0 flash CS, bit 1 SD CS (1 = selected), bit 4 drive the flash pins, bit 8 busy (read-only) |
| `0x450008` | SPI_DIV: bits 7:0 div, SCLK = 36 MHz / (2 × (div + 1)); 0 gives 18 MHz, the reset value 44 400 kHz. Bit 8: SD High Speed, SCLK = 36 MHz on the SD card's pins only (div ignored; see SD card) |
| `0x45000C` | SPI_STREAM: a read waits for the current transfer (the bus is held), returns its 32 bits (first byte received in bits 7:0, so a word store puts them in order) and starts a 32-bit transfer with MOSI high; a write starts one |
| `0x45001C` | SPI_LAST: the same read, without starting another transfer |
| `0x460000` | USB_STATUS: bits 1:0 device (0 none, 1 keyboard, 2 mouse, 3 gamepad), bit 2 the core's watchdog (see USB host), bits 15:8 report count; write bit 0: hold the USB core in reset (it re-enumerates when released) |
| `0x460004` | USB_KEYS: {key3, key2, key1, modifiers} of the last report (its bytes 4, 3, 2, 0; these three registers hold the raw bytes whatever the device, so check USB_STATUS's type first) |
| `0x460008` | USB_KEYS2: key4 (byte 5) |
| `0x46000C` | USB_MOUSE: {dy, dx, buttons} of the last report (bytes 2, 1, 0) |
| `0x460010` | USB_DEBUG: {connected, host driving, D−, D+} in bits 17:14, microcode pc in bits 9:0, for diagnostics; one flop, not synchronized as a word |
| `0x460014` | USB_MOUSE_POS: {y, x}, 16-bit running sums of a mouse's dx and dy (they wrap: subtract two readings) |
| `0x460020`–`0x460034` | the same six registers for the second port |

The I/O region (`0x400000`–`0x7FFFFF`, a 64 KB window per device) is
uncached and goes through the CPU's cacheless data bus. The single interrupt goes to the machine external
interrupt input (`mie` bit 11).

PSRAM offsets given to the video engine are in the interleaved space, as
the CPU sees it at `0x800000`. Anything written through the cache must
be written back (`cbo.clean`) before DMA reads it.

## Video

**Video RAM.** Byte addresses from `0x420000`:

| Range | Contents |
|---|---|
| `0x0000`–`0x07FF` | unused (was the text mode's font); writes are dropped |
| `0x0800`–`0x09FF` | palette: 256 × RGB565, entry *i* at `0x800 + 2i` (initialised xterm-style) |
| `0x0A00`–`0x153F` | line table: one 32-bit entry per line (480 used, room for 720) |

**Line table entry** (from bit 0 up):

| Bits | Field |
|---|---|
| `[14:0]` | PSRAM source, in 256-byte blocks |
| `[21:15]` | scroll offset into the first block, in 2-byte units |
| `[23:22]` | mode: 0 blank, 1 16 bpp RGB565, 2 8 bpp paletted, 3 reserved (blank; was text) |
| `[27:24]` | reserved |
| `[28]` | 8 bpp: 2× horizontally, each source byte two pixels from column VIDEO_HWIN start, black outside the window |
| `[31:29]` | reserved |

A 16 bpp line is 1440 bytes and an 8 bpp line 720 bytes (one palette index
per byte). There used to be a 90-column text mode (character and attribute
cells over an 8×16 font in video RAM); it was removed in favour of drawing
text in software (the boot screen does), which freed about 250 logic cells
and a block RAM.

**Line fetch.** At the start of line L's horizontal blanking (x = 736), the
engine reads line L + 2's entry and DMAs its data into one of two 7-block
line buffers in `hr_ram`. The CPU can change table entries at any time; a
change takes effect two lines later. The vblank interrupt, at the start of
line 480, is the natural point to rewrite the table for the next frame.

## Audio

Samples are 32-bit words: left in bits 15:0, right in bits 31:16. Each half
holds 256 samples, 5.33 ms of sound. The engine plays half A, then half B,
and so on. When it moves on from a half, it raises that half's interrupt. To
refill the half, the CPU writes the samples to PSRAM, cleans them from the
cache, and writes that half's pointer register, which DMAs the data into
`hr_ram`. With AUDIO_CTRL off the engine sends silence.

## SPI flash

The on-board P25Q32U (4 MB, JEDEC ID `85 60 16`) is on pins 59–62: CLK,
CS#, MOSI and MISO. These are the FPGA's MSPI configuration pins, so
`build.tcl` sets `use_mspi_as_gpio`. The FPGA boots from its internal
flash, not from this one.

**Rules for firmware:**

- Set SPI_CTRL bit 4 while using the flash and clear SPI_CTRL (0) when done,
  so the pins float. The JTAG write of the internal flash (`build.sh`)
  failed while a design was driving them: the board was dead afterwards
  and needed a replug.
- Keep bit 4 set between commands. It drives CS# high; the pins' pull-ups
  alone rise too slowly, and the flash then misses the end of a command
  (a write-enable, say).

**Tested:** read (`0x03`) at 13.5 MHz and 3.4 MHz, 4 KB sector erase
(`0x20`, about 10.4 ms) and 256-byte page program (`0x02`, about 1.4 ms),
checked on the last sector (`0x3FF000`). The first bytes hold someone
else's RISC-V image (Sipeed's or a tutorial's). `openFPGALoader -b
tangnano9k --external-flash` can write this flash from the PC, but that
hasn't been tried yet.

## SD card

The slot is on pins 36 (SCLK), 37 (MOSI/CMD), 38 (CS#/DAT3) and 39
(MISO/DAT0), all LVCMOS33 with pull-ups. It shares the SPI master with the
flash (SPI_CTRL bit 1 is its CS). SCLK and MOSI go to the card whenever
the flash isn't selected, so the >= 74 initialization clocks are just
bytes sent with no CS set.

`sd_test()` in `hello.c` initializes the card and then reads only:

1. 80 clocks at 400 kHz (SPI_DIV 44), then CMD0 (expect `01`).
2. CMD8 with `0x1AA`: `01` plus the echo means an SD v2 card.
3. CMD55 + ACMD41 (HCS set) until R1 is `00`. **CS has to be released,
   with 8 clocks, between tries.** Keeping CS low throughout, the test
   card (64 GB SDXC) stayed idle for 2570 tries, while releasing it made
   it ready after 2 tries (4 ms).
4. CMD58: OCR bit 30 set means SDHC/SDXC, which uses sector addressing.
5. SPI_DIV 0 (18 MHz; 13.5 MHz on the 27 MHz design), then CMD6 to
   switch the card to High Speed: if its status block (byte 16) says
   function 1, SPI_DIV bit 8 (36 MHz; a bitstream without it ignores the
   bit and stays at 18). `-DSD_NO_HIGH_SPEED` skips it. Then CMD9 (CSD:
   the capacity), and reads of sector 0 (the MBR) and the first
   partition's boot sector.

On the test card: OCR `C0FF8000`, 59 638 MB, and partition 1 is type `07`
at sector 32768, with boot sector OEM name `EXFAT`.

**Reading data:** `sd_read()` always uses CMD18 and leaves it running:
the card waits mid-transfer, CS low, and a following read of the next
sector just carries on, so the card's access latency is paid once per
sequential run instead of once per request (FatFs reads a file sector by
sector when the pieces are small). A read elsewhere, a write or
`sd_stop()` ends it with CMD12. **Call `sd_stop()` before using the SPI
for anything else** (the flash) and before starting another program
(`loader_start()` does). If a program stopped with the read still open
(or after a reset), CMD0 gets no proper answer: `sd_init()` then sends
CMD12 and tries again. The data blocks come in through SPI_STREAM:
the next 32-bit transfer runs while the CPU stores the last word, so the
SPI clock hardly pauses. With SPI_DATA a byte took about 50 CPU cycles
(0.54 MB/s), the I/O-bus round trips costing twice the 16-cycle transfer.

| Read (4 MB WAD file, through FatFs, 27 MHz design) | SPI_DATA, CMD17 | SPI_STREAM, CMD18 |
|---|---|---|
| in 64 KB pieces | 7.8 s (0.54 MB/s) | 3.7 s (1.13 MB/s) |
| in 1000-byte pieces | 10.8 s | 6.8 s |

**High Speed (36 MHz):** in SPI mode a card is only rated to 25 MHz, so
the 18 MHz above was the limit; after CMD6 it is rated to 50. The SPI
master toggles SCLK on the CPU clock, so 36 MHz needs a clock edge in the
middle of a CPU cycle: with SPI_DIV bit 8 the master moves one bit per
CPU cycle and, instead of its own SCLK, raises `bit_on` during each bit;
`soc.v` makes the pin's clock from it with a `system_clk` (72 MHz) flop,
low in the first half of the cycle and high in the second. The bit is on
MOSI for the whole cycle (the card samples at the rising edge, mid-cycle)
and MISO is sampled at the end of the cycle, 27.8 ns after the falling
edge at which the card changed it. That is the same point as at 18 MHz
(its half period is also one CPU cycle), so the read margin is unchanged:
the pins' delays plus the card's output delay (at most 14 ns) have to fit
in 27.8 ns. The flash stays on the ordinary path (no High Speed clock).
In simulation (`sim/run_sd.sh`, card with 14 ns output delay and 6/4 ns
pin delays), 8 sectors in one call took 70 279 CPU cycles at 18 MHz
(2.1 MB/s) and 37 511 at 36 MHz (3.9 MB/s).

**Driver and filesystem:**

- `firmware/sd.c` / `sd.h`: `sd_init()`, `sd_read()`, `sd_stop()` and
  `sd_write()` (CMD24, or CMD25 for runs of sectors), plus `spi_xfer()`.
- `firmware/fatfs/`: FatFs R0.16 (ChaN, BSD-style license in
  `LICENSE.txt`). `ffconf.h` is set to read-only (unless built with
  `-DFF_FS_READONLY=0`, as `tools/sdput` is), exFAT, long file names
  in a static buffer, code page 437 and volume labels. Writing is one
  option away (`FF_FS_READONLY`).
- `firmware/diskio.c`: connects FatFs to the SD driver (`disk_write` only
  in a writable build).
- `firmware/libc.c` and `include/string.h`: the C functions FatFs and GCC
  need.

The boot test mounts the volume, lists it two levels deep and reads the
first file of 64 KB or more. On the test card it mounted exFAT with 128 KB
clusters and read 117 KB in 89 ms (1.3 MB/s; 301 ms before SPI_STREAM and
CMD18).

**Writing files without taking the card out** (`tools/sdput/`, built on
first use): `sdput.py` loads `sdput.bin` through the serial loader, which
resets the board, and talks to it at 921600 baud. The board writes the
files with a writable FatFs build, creating missing directories, reads
each file back and sends its checksum, which the host compares with its
own.

- `sdput.py sync DIR` brings the card up to date with DIR, a card's file
  tree on the PC (`../sdcard/out/card`, built by
  `../sdcard/make_sdcard.sh`; `make sync` at the top). As rsync does, it
  compares each file's size and time with the card's: the files sdput
  writes get the PC file's time (FAT's fields, UTC). A file of the same
  size with another time is checksummed on the board (about 2.2 MB/s) and
  only sent if it differs; then it just gets the time. Nothing on the card
  is deleted, and `U7/exult.cfg` (Exult keeps its settings there; also
  `--keep PATH`) is only sent when missing. `--dry-run` lists what it would
  send.
- `sdput.py put LOCAL REMOTE [...]` sends files; `ls [DIR]` lists a
  directory with sizes and times; `rawtest` saves the card's last sector,
  writes a pattern to it, reads it back and restores it.

**Protocol** (`sdput.c`): the loader's frames, with the checksum also
covering the block number and length. File data goes in windows of 64
blocks (128 KB): the host sends them back to back, the board puts each in
its RAM slot and acknowledges it ('k' and the block number), the host
resends what wasn't, then COMMIT writes the window to the card in one go
while the host waits: the UART has a 16-byte FIFO and no interrupt, so the
board can't receive while it writes. Nothing slow may happen between two
bytes (the FIFO lasts 0.17 ms): the checksum is summed as the bytes come
in, and the data goes straight to its slot (copying 2 KB through the cache
afterwards lost bytes). About 80 KB/s, against 70 when each 2 KB block
waited for its answer; the rest of the 89 KB/s the link carries goes to
the card writes (about 0.13 s per window). The QUIT command sends the board
back to 115200 baud at once, so that the next run's reset string works; it
also does so after 3 s of silence. The core firmware builds FatFs
read-only; the games write their saves and settings.

## Serial loader

`tools/run.py prog.bin` uploads a program into PSRAM and runs it, then
turns into a terminal: board output goes to stdout, keys go to the board,
and Ctrl-] quits. Close `tio` first, since the script needs the port to
itself. Useful options:

- `--listen N`: print the output for N seconds instead of the terminal.
- `--baud`: the transfer rate (see below).
- `--port`: the serial device. By default the external adapter (CP210x or
  FTDI) if one is plugged in, else the BL702.
- `--no-reset`: skip the reset.
- `--addr`: the load address (default `0x800000`). The loader takes
  programs from `0x800000` up to `0xF80000` (the boot screen's
  framebuffer, then the firmware's own RAM).

**Reset.** It first sends `\x1bM9BRESET`. `rtl/uart.v` matches that
string on every received byte, independently of the CPU, and resets the
whole system like S2. So a hung program can be replaced too, as long as
the UART is at 115200. A serial break would be the usual way, but the
board's USB-serial chip doesn't pass breaks on.

**Protocol** (`firmware/loader.h`):

1. The firmware's main loop matches `\x1bM9BLOAD` followed by a divider
   byte, answers `READY`, and switches to that rate. It disables
   interrupts and video during the transfer.
2. Frames follow: `0xA5`, block number, length (up to 2048), data, and a
   Fletcher-style checksum. The board answers `K`, or `N` plus a reason,
   and the host resends a bad frame.
3. After the last block the board cleans the loaded range from the cache,
   runs `fence.i` and jumps.

**The BL702 USB-serial chip** (it emulates an FT2232) has quirks:

- It applies a new baud rate only when the port is opened, and then it
  uses the rate set before the open. `run.py` sets the rate, closes the
  port, reopens it and sets it again.
- It corrupts bytes now and then, even at 115200: about one 2 KB frame
  in 15 fails its checksum and is resent. The board reports checksum
  mismatches, not timeouts or FIFO overruns.
- Its link seems to get into a bad state after heavy use, needing a
  replug.
- 1.5 Mbaud worked (a 421 KB upload in about 4 s) but less reliably.
  115200 (about 40 s) is the dependable choice.

Reflashing the BL702 with Sipeed's open-source debugger firmware is a
possible fix.

**An external adapter** avoids all that. A CP2102 on the J5 port uploads a
421 KB program at 921600 baud in 4.8 s with no frame resent (`run.py`
starts at 921600 on a CP210x; 1 Mbaud and up don't work with its fixed
rate table).

## USB host

Two ports served by one copy of nand2mario's `usb_hid_host` (low speed,
1.5 Mbit/s: HID keyboards, mice and gamepads in boot protocol) on the 12 MHz
clock. It enumerates each port's device and then keeps it alive and polls
it, switching between the ports once per millisecond frame.

**Wiring** (header J5, LVCMOS33, 4 mA, internal pull-downs), for USB-A
sockets:

| Socket | Port 0 | Port 1 |
|---|---|---|
| D− (pin 2, usually white) | pin 25 | pin 27 |
| D+ (pin 3, usually green) | pin 26 | pin 28 |
| VBUS (pin 1) | 5V (header J6) | 5V |
| GND (pin 4) | GND (header J6) | GND |

**Fit 15 kΩ resistors from D− and D+ to ground** on each socket, as the
USB spec asks of a host. Without them it mostly works (the tests ran
without them), but the test keyboard (a USB/PS/2 combo) sometimes comes up
in PS/2 mode with both lines high, and then never answers: always when the
board powers up with the keyboard plugged in (the unconfigured FPGA's pins
have weak pull-ups), and now and then when it is plugged into the running
design. Only unplugging it gets it out of that state. `usbstate` shows it
as "both" high. A load or flash of the FPGA also failed its CRC check
every time while such a keyboard sat on the design's USB pins. A low-speed device
pulls D− up to 3.3 V through 1.5 kΩ, so the pulled-up pin tells which wire
is D− whatever the socket's markings say. USB_DEBUG shows it (D− high while
idle), and `tools/usbdiag/usbstate` prints it.

**Registers** (`rtl/usb_port.v`): each report is announced with a toggle,
and the CPU side copies the core's report bytes 0–5, which hold until the
next report (at least 1 ms), a few cycles later. The report counter
increments, a mouse's motion is added to USB_MOUSE_POS (so a program that
polls once a frame loses none), and IRQ bit 3 is set (either port). The firmware's main loop echoes a keyboard's keys (US
layout) on the UART.

**Changes to the upstream core** (`rtl/usb_hid_host.v`, marked `m9b`):

- **Watchdog:** it resets the microcode if nothing arrives for a while,
  but the `start` instruction (wait for the device's reply) reset it on
  every cycle while waiting. A device that never answered hung the core
  for good. Now only a reply that has begun counts.
- **Watchdog after a reset:** the counter wasn't cleared by the core's
  reset, and when it fired it left the output enabled. Fired during a bus
  reset, that held the bus in SE0 forever. Now reset clears it, and firing
  releases the bus.
- **Debug output** (`dbg_ukp`, USB_DEBUG).
- **Raw report bytes:** upstream decodes the report into key, mouse and
  gamepad outputs by device type, and `mouse_dx`/`dy` were cleared right
  after the report pulse. The core now keeps bytes 0–5 of the last report
  as they came (any device type), held until the next report, and
  software decodes them.
- **Smaller:** the 1 ms frame timer is outside (`usb_sof` in `soc.v`),
  the watchdog counts frames instead of 12 MHz cycles (10 bits, was 24),
  and the microcode pc is 10 bits (was 14; the program is 536 nibbles).
  With the raw bytes and one synchronizing flop on USB_DEBUG, that saved
  about 90 logic cells and 165 registers for the two ports (commit
  8ceeeef). A differential simulation against the previous core (random
  device traffic, 12 seeds of 1.5 s) matched cycle for cycle except for
  the watchdog's new timeout.
- **One engine for both ports:** the microcode waits for the next 1 ms
  frame (WAIT) between bursts of transactions, and only its pc, return
  address, W register and connected flag are live across a WAIT. So when
  the running port reaches a WAIT before its frame and the other port has
  a frame pending, the engine swaps those with the other port's saved copy
  and runs that port. Each port keeps its own bus drive (a bus reset holds
  SE0 across frames), watchdog and device type; the descriptor and report
  buffers are shared (the descriptor fields are checked within one burst,
  and `usb_port.v` copies the report bytes within cycles of the report). A
  port held in reset gives the engine to the other. One port's poll delays
  the other's keep-alive by up to about 0.3 ms, well within the 3 ms after
  which a device suspends. A new **transaction timeout** (START to the end
  of the receive routine, 2048 cycles, about 170 us) sends a port whose
  device doesn't answer back to the start of its program; before, that
  waited for the watchdog (768 ms), which would now stall the other port
  too. Saved about 136 logic cells and 150 registers over two engines.
  Tested with `sim/run_usb.sh` (see Simulation) and on the board.

The watchdog fires after 768 ms without a reply (it was about 1 s), and
USB_STATUS bit 2 (upstream's `conerr`) is its top bit, set from 512 ms: it
comes on every 768 ms whenever no device is enumerated, including
with nothing plugged in. It is not a connection error in itself.

**Diagnostics** (`tools/usbdiag/`, `make`, then `tools/run.py
tools/usbdiag/build/<name>.bin --listen 10`; add `--no-reset` to look at a
state without resetting the USB cores):

- `usbstate`: for each port in turn, for 1 s, the share of time the device looked connected and
  the host drove the bus, the line levels, and where the microcode spent
  its time (addresses in upstream's `ukp.s`).
- `usbbus`: resets port 0's core (`make clean; make PORT=1` for port 1) and records every change of {host driving,
  D−, D+} for 600 ms: bus reset, keep-alives, packets, and whether the
  device answers. At about 1.4 samples per µs it shows activity, not bits.
- `usbreport`: each report on either port (keys, or mouse buttons, motion
  and USB_MOUSE_POS). It stops printing reports after 200, and an idle
  keyboard sends one every 500 ms.

**Bring-up notes:**

- The first socket breakout had D+ and D− the other way round from its
  silkscreen, and a contact problem. The keyboard was detected but never
  answered, and mice showed no pull-up at all. A different connector fixed
  everything.
- The second port's first connector showed both lines high with the
  keyboard: that was the PS/2 fallback above, not the connector.
- The core's packets were checked in simulation (a pulled-up D−, the bus
  decoded: SETUP and DATA0 with valid CRCs, 8 clocks per bit).

## PSRAM controller

- **Configuration:** CR0 = `0x8f1c` on both dies: 6-clock fixed 2× latency,
  128-byte wrapped bursts. It is written about 200 µs after reset, past
  tVCS. The chip is rated for 166 MHz at this latency.
- **Burst types:** cache-line transfers are 8-beat bursts, cut short by
  raising CS#. DMA uses full 256-byte blocks, 128 bytes per die. The
  W955D8MBYA has no linear bursts, so every burst wraps within the CR0
  length.
- **Priority:** cache-line requests (the CPU is stalled on them) go before
  DMA, and are slotted in between DMA bursts.
- **Calibration:** `CLK_DELAY` 67 and `READ_DELAY` 71 were set on this
  board at 148.5 MHz; they also passed at 162 MHz and pass at the
  current 144 MHz.

## Building

Requires a `riscv64-unknown-elf-gcc` toolchain (Ubuntu's
`gcc-riscv64-unknown-elf`), Python 3, `openFPGALoader`, and the Gowin IDE
(Gowin EDA V1.9.11.03 Education, free from Gowin's site, which needs no
license file for the GW1NR-9). The scripts find the IDE through
`GOWIN_HOME`, the directory holding `bin/gw_sh` (default `~/gowin/IDE`), and
run it through `tools/gw_sh.sh`, which sets up the libraries it needs on a
current distribution. The simulations take Gowin's primitives from
`$GOWIN_HOME/simlib/gw1n/prim_sim.v` and need Icarus Verilog.

```
./build.sh            # firmware + bitstream, then flash both
./build.sh --build    # firmware + bitstream only
./build.sh --flash    # flash the existing bitstream and firmware
./build.sh --fw       # rebuild the firmware only and flash it (no synthesis)
```

**Flashing:** it writes the FPGA's **internal flash**, so the board boots
the design on power-up:

```
openFPGALoader -b tangnano9k -f --user-flash firmware/firmware.bin impl/pnr/core.fs
```

That writes the bitstream and the firmware (into the user flash) together
in about 13 s. openFPGALoader can only write the user flash together with a
bitstream, but the bitstream doesn't depend on the firmware, so a firmware
change needs no synthesis. The image is a raw little-endian binary: word *i*
of the flash is the 32-bit word at file offset 4*i*.

**Linking:** `firmware/link.ld` puts code and read-only data in the flash
(`.data` is loaded from there) and RAM in the top 128 KB of PSRAM
(`0xFE0000`) for `.data`, `.bss` and the stack. `crt0.S` copies `.data`
and clears `.bss`, so a button reset restarts cleanly. The chime's audio
buffers are in `.bss` too: their refills go on during the boot screen,
while a program loads from the card.

**Programs** link with `runtime/m9b.ld` (picolibc's script with one
region, the 8 MB): the image from `0x800000`, where the loader puts it
and jumps, `.data` in place after the code, then `.bss`, the heap, and the
stack at the top (`--defsym=__stack_size=...` before `-T`). Once a program
runs, all of PSRAM is its own.

`build.tcl` uses the higher-effort place & route options, and releases the
MSPI pins as I/O (see SPI flash).

Both firmware Makefiles link `-lgcc`, for GCC's helpers (64-bit shifts,
division and so on). There is no C library: code that needs `memset` and
friends (GCC emits calls to them for things like `= {0}` on arrays) has to
supply them.

Serial port: 115200 8N1, on two ports at once. TX goes out on both and
RX is the AND of both (`top.v`), so either works for the console, the
loader and the reset string (one at a time):

- the board's BL702 (it emulates an FT2232: interface 0 is JTAG,
  interface 1 the UART), pins 17 (TX) and 18 (RX);
- an external 3.3 V USB-serial adapter on header J5: pin 29 is the
  FPGA's TX (to the adapter's RX), pin 30 its RX (pulled up), plus GND
  (J6). Don't connect the adapter's 5 V or VCC.

`ttyUSB` numbers depend on plug order, so use `/dev/serial/by-id/`: for
example `tio /dev/serial/by-id/usb-Silicon_Labs_CP2102*` for a CP2102, or
`.../usb-SIPEED_JTAG_Debugger_*-if01-port0` for the BL702. After replugging
the board, run `stty -F <port> 115200` before starting `tio` on the BL702,
or the output comes out garbled. Button S2 is reset.

JTAG sometimes fails, typically after replugging or with HDMI connected:
`unable to open ftdi device`, a wrong IDCODE, or a CRC failure after
loading. Replugging fixes it. The board also doesn't behave well when
powered from both the USB and the HDMI side. Without a terminal,
openFPGALoader prints only its first lines; run it under
`script -qec "..." log` to see the result, including the `CRC check` line.

**Internal-flash writes can fail.** With an SD card inserted, about half of
the writes failed (`CRC check : FAIL`), whether or not the firmware had
initialized the card. Without a card, every write passed. That points at
the board's supply rather than the design. openFPGALoader still exits 0,
so `build.sh` runs it under `script`, checks for `CRC check: Success`, and
retries up to 3 times. Separately, writes also failed while the design
drove the MSPI pins, hence the SPI_CTRL bit 4 rule (see SPI flash). After
a failed write the board is unconfigured, and it sometimes needs a replug
before the next write works.

## Simulation

All simulations use iverilog with Gowin's `prim_sim.v`:

- `sim/run.sh`: PSRAM controller against `psram_model.v`. It covers the CR0
  write, DMA bursts and line transfers, and `run.sh sweep` tries a range
  of read delays.
- `sim/run_video.sh`: video engine, video RAM, `hr_ram` and controller,
  without the CPU. It checks every pixel of a short frame with all three
  modes and scroll offsets, plus 300 audio packets.
- `sim/run_soc.sh`: the whole SoC running `sim/fw/sim_main.c`, loaded into
  the user flash model through a backdoor. It covers booting from the
  flash, PSRAM through the caches, code executing from PSRAM, a white frame
  checked pixel by pixel, vblank interrupts, byte stores in every lane,
  and the SPI flash (`spi_flash_model.v`: JEDEC ID, and reads through SPI_DATA and SPI_STREAM). Pass
  `+fst` for a waveform dump. `psram_model.v` holds only 256 KB (addresses
  wrap), so the test program keeps its buffers between 64 KB and 104 KB:
  its data and stack, in the top 128 KB, land at 128 KB .. 256 KB. The flash pins have pull-ups
  in the testbench as on the board; without them, a floating MISO turned
  into X, which reached a load address and tripped VexiiRiscv's "Multiple
  way hit" assertion.
- `sim/run_sd.sh`: the SD driver (`firmware/sd.c`, run by
  `sim/fw_sd/sd_main.c`) against `sim/sd_card_model.v` (SPI mode: init,
  CMD6, CMD9, CMD17/18/12), wired to the SD pins with `-DSD_MODEL` and
  board-like pin delays. It checks the High Speed switch, reads streamed
  across calls, non-sequential reads, recovery from a read left open and
  every byte read, and prints the cycles for 8 sectors at 36 and 18 MHz.
  The model puts out X from 2.5 ns to 14 ns after each falling SCLK edge
  (the SD output hold and delay limits), so sampling outside the valid
  window shows up as bad data, and it counts MOSI setup violations.
  `-DSD_TODLY=19.0` (too slow a card) makes the reads fail.
- `sim/run_usb.sh`: the USB host core with both ports against two
  low-speed device models (`sim/usb_ls_device.v`: NRZI and bit stuffing,
  SETUP/IN with descriptors in 8-byte packets, random NAKs, HID reports on
  endpoint 1, SET_ADDRESS, bus reset). Scenarios: keyboard + mouse, a dead
  device (pulled up, never answering) on either port, nothing on port 0,
  and unplug/replug plus a port reset. It checks the device types, every
  report the host takes against what the device sent, and the longest
  keep-alive gap per port; `--old` adds the single-port core of 8ceeeef
  for reference.
- `sim/tb_ufm.v`: `ufm.v` against Gowin's FLASH608K model (build command in
  the file).
- `sim/tb_uart.v`: `uart.v`. It covers 3 Mbaud with a 1% slow sender, the
  FIFO and its overrun flag, and a polling CPU's strobe-then-sample reads
  while bytes arrive at every possible moment (build command in the file).

## Notes

- **Why 720×480:** at 1280×720 (742.5 Mbit/s per TMDS channel on emulated
  LVDS outputs) the link was marginal. Any CPU activity added enough jitter
  to lose a strict monitor, and a tolerant one showed noise and blinked. We
  ruled out the TMDS drive strength, PSRAM traffic, the power supply and
  the HDMI PLL's reference, and the effect changed from build to build with
  placement. At 270 Mbit/s the link is solid.
- **VexiiRiscv:** `rtl/VexiiRiscv.v` is generated from the fork
  [the-parts-bin/m9b-VexiiRiscv](https://github.com/the-parts-bin/m9b-VexiiRiscv),
  branch `m9b` (`b4c9beb`): upstream `dev` at `42268af` plus the
  black-box option below, `--lsu-l1-wishbone-unbuffered` (the data L1's
  bus command without its register stage, see Clocks, Timing),
  `--with-rvZicboz` (`cbo.zero` fills a line in the data L1 with zeros
  without reading PSRAM), `--btb-target-width` (with an 11-bit hash and
  21 target bits a BTB entry is 36 bits, one block instead of two) and
  `--lsu-l1-word-writes` (the data L1 banks are written in whole CPU
  words; a store merges its bytes into the word as read, through the L1
  bypass, which the option turns on). Note the fork's commit here when
  regenerating. It is generated in the fork's Docker image (entrypoint
  `bash`; the default one starts a VNC desktop) with:
  `sbt "runMain vexiiriscv.Generate --xlen 32 --physical-width 24 --with-rvm --with-rvZcbm --with-rvZba --lsu-software-prefetch
  --reset-vector 0 --allow-bypass-from 0 --with-btb --with-ras
  --relaxed-branch --relaxed-shift --regfile-async --fetch-l1 --fetch-wishbone
  --fetch-l1-sets 128 --fetch-l1-ways 1 --fetch-l1-mem-data-width-min 64
  --lsu-l1 --lsu-l1-wishbone --lsu-wishbone --lsu-l1-sets 128
  --lsu-l1-ways 2 --lsu-l1-mem-data-width-min 64
  --with-rvZicboz --lsu-l1-word-writes --lsu-l1-wishbone-unbuffered
  --div-radix 4
  --btb-hash-width 11 --btb-target-width 21
  --region base=0,size=20000,main=1,exe=1
  --region base=800000,size=800000,main=1,exe=1
  --region base=400000,size=400000,main=0,exe=0"`.
  - **24-bit addresses** (`--physical-width 24`, 2026-10-16; the map
    was 0x00000000 flash, 0x40000000 PSRAM, 0x80000000 I/O): without an
    MMU VexiiRiscv makes the PC, virtual and physical addresses and the
    trap value that wide, so every PC copy in the pipeline, the branch
    and PC adders, the LSU's address stages and the cache tags (19 to 11
    bits) shrink. It saved 258 logic cells (7621 to 7363) and 190
    registers, and the CPU clock went from 36.05 to 39.96 MHz (the
    critical path, BTB read to PC increment, runs through the PC adder).
    The software moved with it (`firmware/m9b_map.h`).
  - **Data L1 shape:** 128 sets × 2 ways × 64-byte lines = 16 KB. Each
    way's bank (1024 × 64) has a write mask per 32-bit word, not per
    byte, so Gowin makes it from two 1024 × 32 arrays with plain write
    enables, 2 blocks each: 8 blocks, as the direct-mapped 16 KB took
    (one 2048 × 8 block per byte lane). On the Doom timedemo the second
    way is worth 14%: Doom's data misses were mostly conflicts.
  - **Why word writes: the BSRAM byte enables misbehave.** Before, a
    partial write with write-mask bit 0 clear often still wrote lane 0
    (SDPB, x32 and x16). `tests/bsram_be` (all 26 blocks as DPB x16)
    found the rule on 2026-10-16: when a port writes in two consecutive
    cycles, a byte lane enabled in the first write and disabled in the
    second is written anyway, in 10-36% of cases, on every block and at
    27, 36 and 72 MHz. An idle cycle, a read or a write on the other port
    in between avoids it, and full-word writes never fail. Gowin's
    simulation model doesn't do this. So the data L1 never writes partial
    words: `--lsu-l1-word-writes` makes a store write its whole 32-bit
    word, its bytes merged over the word as read (through the L1 bypass,
    which includes stores still in the pipeline). The firmware's store
    width test checks every lane at boot.
  - **The black-box option:** `--blackbox-byte-enables`, added in the
    fork's `src/main/scala/vexiiriscv/Generate.scala`, is currently
    **not used**. It makes memories with masked writes (the data L1 banks, and the branch
    predictor, whose one-bit mask is just a write enable) come out as
    `Ram_1w_1rs` instances, implemented by `rtl/Ram_1w_1rs.v` with SDPB
    byte enables. That is the path that failed as described above.
  - **Tag memories:** left for Gowin to place. Forcing them into
    distributed RAM (`(* syn_ramstyle = "distributed_ram" *)` on the
    `*_ways_*_mem` arrays) freed about one block per tag memory, for a few
    percent more logic.
  - `main=1` regions go through the L1s, as whole-line transfers only; the
    rest go through the cacheless bus.
  - `--relaxed-branch` is needed to meet 27 MHz, `--relaxed-shift` (the
    shifter's result is bypassed a stage later) for 36 MHz. `--relaxed-btb`
    didn't route (a congestion hotspot), and `--relaxed-btb-hit` needs it.
  - In simulation its memories start as X, so `sim/vexii_mem_init.vh`
    zeroes them (also those inside `Ram_1w_1rs` instances, if the
    black-box option is used). Regenerate it (`sim/gen_vexii_mem_init.py`)
    whenever the core is regenerated.
- **User flash timing:** UG295 gives a 25 ns access time. `ufm.v` takes 4
  CPU cycles per word, dropping XE/YE between words: the datasheet's
  read diagram does, and Gowin's simulation model only starts a read from
  idle. A 64-byte line is about 80 cycles; the L1s hide most of that.
  Programming and erasing from the fabric (PROG/ERASE/NVSTR) aren't wired
  up yet.
- **Gowin synthesis quirks:**
  - no forward references to signals or `localparam`s
  - no expressions on primitive ports (use wires)
  - functions may only use their arguments
  - a byte-enable RAM inferred from an array gets one BSRAM per byte lane
    (and the BSRAMs' own byte enables are unreliable, see above; the old
    `ram64.v` boot RAM used them too). The three banks in `vram.v` exist
    because one 1536-word array was rounded up to 4 blocks.
- **UART:** `rtl/uart.v` replaced an earlier UART (FemtoRV's
  `uart_picosoc_shrunk.v`, adapted), which had a fixed divider and a
  one-byte buffer. Its receive FIFO pops in the
  cycle the CPU samples the data, judged by the FIFO state at that point;
  judging at the strobe read a byte twice when it arrived between the two
  (`sim/tb_uart.v` tests exactly that).
- **Unused files:** `Ram_1w_1rs.v` (the black-box option above) and
  `gpu.sv` with its RAMs (the `HDMI_TEST_PATTERN` option, still drawing a
  1280-wide pattern). The earlier stages' files (the FemtoRV and VexRiscv
  cores, the boot RAM before the user flash, the old UART) are in the
  history.

## Changes to the third-party parts

- **VexiiRiscv:** generated with m9b's options, five of them added in the
  fork (`--lsu-l1-wishbone-unbuffered`, `--with-rvZicboz`,
  `--btb-target-width`, `--lsu-l1-word-writes`, and the unused
  `--blackbox-byte-enables`); the generator command and the reasons are
  under Notes.
- **HDMI core** (`rtl/hdmi/`): 720 × 480 at 59.94 Hz on a 27 MHz pixel
  clock (the video timing, the AVI InfoFrame's video code 2 and 4:3
  aspect, the audio clock regeneration's CTS of 27000 for 48 kHz); the
  serializer is Gowin's OSER10 (10:1, DDR), its pixel clock phase-aligned
  with the bit clock through a CLKDIV (Clocks); the TMDS channel encoder is
  split into three pipeline stages.
- **USB host** (`rtl/usb_hid_host.v`, marked `m9b`): the watchdog fixes,
  raw report bytes, a smaller core and one engine for both ports, listed
  under USB host.
- **FatFs:** only its configuration, `firmware/fatfs/ffconf.h` (marked
  `m9b`, see SD card).
- **picolibc's linker script** (`runtime/m9b.ld`): one memory region, the
  8 MB of PSRAM from `0x800000` (Building).

## License

Apache License 2.0 (`LICENSE`), apart from the third-party parts:

| Part | License |
|---|---|
| `rtl/VexiiRiscv.v` | MIT (`rtl/VexiiRiscv.LICENSE`) |
| `rtl/hdmi/` | MIT or Apache 2.0 (`rtl/hdmi/LICENSE-*`) |
| `rtl/usb_hid_host*` | Apache 2.0 (`rtl/usb_hid_host.LICENSE`) |
| `firmware/fatfs/` | FatFs license, BSD-style (`firmware/fatfs/LICENSE.txt`) |
| `firmware/fonts/` | CC0 1.0 (`PixelOperator-LICENSE.txt`) |
| `runtime/m9b.ld` | picolibc's linker script, BSD 3-clause (in the file), changed |
