// CPU, memories, PSRAM path and the video/audio engine, without the HDMI
// encoding, so it can be simulated on its own (sim/tb_soc.v).
//
//   - CPU  : VexiiRiscv (see README: the extensions, the L1 caches and the
//            fork it is generated from)
//   - Addresses are 24 bits (the CPU's physical width: anything above traps;
//     firmware/m9b_map.h has the map for software).
//   - Memory (cached, through the L1s):
//       0x000000 - 0x012FFF : user flash, 76 KB, read-only (writes are
//                             ignored): the firmware, executed in place
//       0x800000 - 0xFFFFFF : HyperRAM, 8 MB (both dies interleaved)
//   - I/O (uncached, through the CPU's cacheless data bus), 0x400000 -
//     0x7FFFFF, a 64 KB window per device:
//       0x410000                : UART_DATA   read: {tx_busy, rx_valid,
//                                 rx_byte}, takes the byte from the RX FIFO;
//                                 write: send a byte
//       0x410004                : UART_STATUS bit 0 tx busy, bit 1 rx valid,
//                                 bit 2 rx overrun (write 1 to clear)
//       0x410008                : UART_DIV    bit period in 27 MHz cycles
//                                 (234: 115200 baud, 18: 1.5 M, 9: 3 M)
//       0x420000   - 0x4217FF   : video RAM (word writes only; see vram.v)
//       0x430000                : VIDEO_CTRL  bit 0: video enable
//       0x430004                : IRQ_PENDING bit 0: vertical blank,
//                                 bit 1: audio half A done, bit 2: half B,
//                                 bit 3: USB report
//                                 (read; write 1s to clear)
//       0x430008                : IRQ_ENABLE  (same bits)
//       0x43000C                : AUDIO_CTRL  bit 0: audio enable
//       0x430010                : AUDIO_PTR_A PSRAM byte address (256-byte
//       0x430014                : AUDIO_PTR_B aligned, interleaved space) of
//                                 1 KB of samples; writing one DMAs it
//                                 into that half
//       0x430018                : VIDEO_HWIN  bits 9:0 first column, 25:16
//                                 end column of 2x lines (reset 40, 680)
//       0x440000   - 0x44000C   : video x_cnt, y_cnt, frame_cnt, clock_cnt
//       0x450000                : SPI_DATA    write: send a byte; read: the
//                                 last byte received
//       0x450004                : SPI_CTRL    bit 0: flash CS, bit 1: SD CS
//                                 (1 = selected); bit 4: drive the flash
//                                 pins (else they float); bit 8: busy (read).
//                                 SCLK/MOSI go to the SD card unless the
//                                 flash is selected.
//       0x450008                : SPI_DIV     SCLK = 27 MHz / (2 (div + 1))
//       0x45000C                : SPI_STREAM  read: waits for the transfer,
//                                 returns its last 32 bits (first byte in
//                                 7:0) and starts a 32-bit transfer of
//                                 ones; write: starts one
//       0x45001C                : SPI_LAST    read: the same, without
//                                 starting another
//       0x460000   - 0x460014   : USB port 0 (pins 25/26), see usb_port.v:
//                                 STATUS, KEYS, KEYS2, MOUSE, DEBUG,
//                                 MOUSE_POS
//       0x460020   - 0x460034   : USB port 1 (pins 27/28), the same
//     (a report on either port sets IRQ bit 3)
//       0x470000   - 0x470010   : PERF        free-running counters: CPU
//                                 cycles with a data L1 / fetch L1 bus
//                                 transaction open, data refills, data
//                                 write-backs, fetch refills
//
// Clocks: the CPU and its buses on cpu_clk and the video engine on
// pixel_clk (both the 27 MHz pixel clock in top.v; they are kept apart
// here, with synchronizers between them, so either can change); the PSRAM
// controller on system_clk (81 MHz, 3x the pixel clock, from another PLL:
// treated as asynchronous).

// `define PERF_COUNTERS   // L1 bus counters at 0x470000 (measurement builds)

`include "VexiiRiscv.v"
`include "uart.v"
`include "psram_bridge.v"
`include "vram.v"
`include "video_engine.v"
`include "ufm.v"
`include "spi.v"
`include "usb_hid_host_rom.v"
`include "usb_hid_host.v"
`include "usb_port.v"

module soc #(
  // cpu_clk: 0 = 27 MHz (the pixel clock), 1 = 36 MHz (system_clk / 2, the
  // PSRAM bridge synchronous). CLOCK_CNT, the UART and SPI dividers count
  // cpu_clk cycles either way (software: firmware/clock.h).
  parameter CPU_36MHZ = 1
) (
  input  wire        cpu_clk,
  input  wire        rst_n,        // cpu_clk domain
  input  wire        pixel_clk,    // video engine
  input  wire        pix_rst,      // pixel_clk domain
  input  wire        system_clk,   // PSRAM controller (memory_clk / 2)
  input  wire        memory_clk,

  input  wire        rxd,
  output wire        txd,
  output wire        uart_reset,   // "\x1bM9BRESET" received (see uart.v)

  // Video timing (pixel_clk domain), from hdmi.sv; also readable by the
  // CPU (read without synchronization: fine for polling, not for anything
  // exact).
  input  wire [11:0] x_cnt,
  input  wire [9:0]  y_cnt,
  input  wire [9:0]  y_cnt_next,
  input  wire [31:0] frame_cnt,

  // Picture and sound for hdmi.sv (pixel_clk domain).
  output wire [23:0] rgb,
  output wire [63:0] audio_pair,     // {s1 R, s1 L, s0 R, s0 L}
  output wire        audio_ready,
  input  wire        audio_used,
  output wire [6:0]  audio_frame_counter,

  // SPI flash (on-board P25Q32U)
  output wire        flash_clk,
  output wire        flash_cs_n,
  output wire        flash_mosi,
  input  wire        flash_miso,

  // SD card (SPI mode)
  output wire        sd_clk,
  output wire        sd_cs_n,
  output wire        sd_mosi,
  input  wire        sd_miso,

  // USB host (low speed), two ports, with their 12 MHz clock
  input  wire        usb_clk,
  inout  wire        usb_dm,
  inout  wire        usb_dp,
  inout  wire        usb2_dm,
  inout  wire        usb2_dp,

  // PSRAM, both dies
  output wire [1:0]  O_psram_ck,
  output wire [1:0]  O_psram_ck_n,
  inout  wire [1:0]  IO_psram_rwds,
  inout  wire [15:0] IO_psram_dq,
  output wire [1:0]  O_psram_reset_n,
  output wire [1:0]  O_psram_cs_n
);

  // -------------------------------------------------------------------
  // CPU
  // -------------------------------------------------------------------
  // Three Wishbone masters: the fetch L1 and the data L1 move whole
  // 64-byte lines (8-beat bursts on 64-bit buses) to/from the memory
  // regions; the cacheless data bus does single 32-bit I/O accesses.
  wire        fl1_cyc, fl1_stb, fl1_we, fl1_ack;
  wire [20:0] fl1_adr;
  wire [63:0] fl1_dat_w;
  wire [7:0]  fl1_sel;
  wire [2:0]  fl1_cti;
  wire        dl1_cyc, dl1_stb, dl1_we, dl1_ack;
  wire [20:0] dl1_adr;
  wire [63:0] dl1_dat_w;
  wire [7:0]  dl1_sel;
  wire [2:0]  dl1_cti;
  wire [63:0] mbus_dat_r;
  wire        dio_cyc, dio_stb, dio_we, dio_ack;
  wire [21:0] dio_adr;
  wire [31:0] dio_dat_w;
  wire [3:0]  dio_sel;
  wire [31:0] mem_rdata;
  wire        irq;

  VexiiRiscv CPU (
    .clk(cpu_clk),
    .reset(~rst_n),
    .PrivilegedPlugin_logic_rdtime(64'd0),
    .PrivilegedPlugin_logic_harts_0_int_m_timer(1'b0),
    .PrivilegedPlugin_logic_harts_0_int_m_software(1'b0),
    .PrivilegedPlugin_logic_harts_0_int_m_external(irq),
    .FetchL1WishbonePlugin_logic_bus_CYC(fl1_cyc),
    .FetchL1WishbonePlugin_logic_bus_STB(fl1_stb),
    .FetchL1WishbonePlugin_logic_bus_ACK(fl1_ack),
    .FetchL1WishbonePlugin_logic_bus_WE(fl1_we),
    .FetchL1WishbonePlugin_logic_bus_ADR(fl1_adr),
    .FetchL1WishbonePlugin_logic_bus_DAT_MISO(mbus_dat_r),
    .FetchL1WishbonePlugin_logic_bus_DAT_MOSI(fl1_dat_w),
    .FetchL1WishbonePlugin_logic_bus_SEL(fl1_sel),
    .FetchL1WishbonePlugin_logic_bus_ERR(1'b0),
    .FetchL1WishbonePlugin_logic_bus_CTI(fl1_cti),
    .FetchL1WishbonePlugin_logic_bus_BTE(),
    .LsuL1WishbonePlugin_logic_bus_CYC(dl1_cyc),
    .LsuL1WishbonePlugin_logic_bus_STB(dl1_stb),
    .LsuL1WishbonePlugin_logic_bus_ACK(dl1_ack),
    .LsuL1WishbonePlugin_logic_bus_WE(dl1_we),
    .LsuL1WishbonePlugin_logic_bus_ADR(dl1_adr),
    .LsuL1WishbonePlugin_logic_bus_DAT_MISO(mbus_dat_r),
    .LsuL1WishbonePlugin_logic_bus_DAT_MOSI(dl1_dat_w),
    .LsuL1WishbonePlugin_logic_bus_SEL(dl1_sel),
    .LsuL1WishbonePlugin_logic_bus_ERR(1'b0),
    .LsuL1WishbonePlugin_logic_bus_CTI(dl1_cti),
    .LsuL1WishbonePlugin_logic_bus_BTE(),
    .LsuCachelessWishbonePlugin_logic_bridge_down_CYC(dio_cyc),
    .LsuCachelessWishbonePlugin_logic_bridge_down_STB(dio_stb),
    .LsuCachelessWishbonePlugin_logic_bridge_down_ACK(dio_ack),
    .LsuCachelessWishbonePlugin_logic_bridge_down_WE(dio_we),
    .LsuCachelessWishbonePlugin_logic_bridge_down_ADR(dio_adr),
    .LsuCachelessWishbonePlugin_logic_bridge_down_DAT_MISO(mem_rdata),
    .LsuCachelessWishbonePlugin_logic_bridge_down_DAT_MOSI(dio_dat_w),
    .LsuCachelessWishbonePlugin_logic_bridge_down_SEL(dio_sel),
    .LsuCachelessWishbonePlugin_logic_bridge_down_ERR(1'b0),
    .LsuCachelessWishbonePlugin_logic_bridge_down_CTI(),
    .LsuCachelessWishbonePlugin_logic_bridge_down_BTE()
  );

  // -------------------------------------------------------------------
  // Memory bus (64-bit): fetch L1 + data L1 -> boot RAM / PSRAM bridge
  // -------------------------------------------------------------------
  // Arbiter: when idle the data L1 wins; the winner keeps the bus until
  // it drops CYC, so a line burst isn't interrupted.
  reg  mb_locked, mb_dl1;
  wire mb_sel_dl1 = mb_locked ? mb_dl1 : dl1_cyc;
  wire        mb_cyc   = mb_sel_dl1 ? dl1_cyc   : fl1_cyc;
  wire        mb_stb   = mb_sel_dl1 ? dl1_stb   : fl1_stb;
  wire        mb_we    = mb_sel_dl1 ? dl1_we    : fl1_we;
  wire [20:0] mb_adr   = mb_sel_dl1 ? dl1_adr   : fl1_adr;
  wire [63:0] mb_dat_w = mb_sel_dl1 ? dl1_dat_w : fl1_dat_w;
  wire [7:0]  mb_sel   = mb_sel_dl1 ? dl1_sel   : fl1_sel;
  wire [2:0]  mb_cti   = mb_sel_dl1 ? dl1_cti   : fl1_cti;
  always @(posedge cpu_clk) begin
    if (~rst_n) begin
      mb_locked <= 1'b0;
      mb_dl1    <= 1'b0;
    end else begin
      mb_locked <= mb_cyc;
      mb_dl1    <= mb_sel_dl1;
    end
  end

  wire mb_is_psram = mb_adr[20];   // byte address bit 23
  // Read beats from the PSRAM bridge (br_rd_ack, registers only) are routed
  // by the registered master select: they never come in a burst's first
  // cycle, so mb_dl1 holds the burst's master by then. They need no target
  // check: the bridge only sees PSRAM cycles and only acks reads within a
  // read burst it accepted, which the master holds on the bus until its
  // last beat. (A registered target select, taken when the bus was locked,
  // was wrong: a master can run several bursts in one CYC -- the data L1:
  // a refill from the user flash, then a write-back and a refill in PSRAM --
  // and the PSRAM refill's beats were masked, hanging the CPU.) Everything
  // else is routed as before.
  wire mb_ack_other;
  wire br_rd_ack;
  wire mb_rd_ack = br_rd_ack;
  assign dl1_ack = (mb_ack_other & mb_sel_dl1) | (mb_rd_ack & mb_dl1);
  assign fl1_ack = (mb_ack_other & ~mb_sel_dl1) | (mb_rd_ack & ~mb_dl1);
  wire mb_ack = mb_ack_other | mb_rd_ack;

  // User flash: each 64-bit beat is two 32-bit flash reads (word 2n, then
  // 2n + 1; about 10 cycles). Writes are acked and dropped (nothing should
  // write there, but a dirty line could still be evicted to it).
  reg         uf_ack, uf_busy, uf_hi;
  reg  [31:0] uf_lo;
  reg  [63:0] uf_rdata;
  wire        uf_sel = mb_cyc & mb_stb & ~mb_is_psram & ~uf_ack;
  wire        ufm_busy, ufm_done;
  wire [31:0] ufm_data;
  reg         ufm_req;
  reg  [14:0] ufm_addr;
  always @(posedge cpu_clk) begin
    uf_ack  <= 1'b0;
    ufm_req <= 1'b0;
    if (~rst_n) begin
      uf_busy <= 1'b0;
      uf_hi   <= 1'b0;
    end else if (!uf_busy) begin
      if (uf_sel && mb_we) begin
        uf_ack <= 1'b1;
      end else if (uf_sel && !ufm_req) begin
        uf_busy  <= 1'b1;
        uf_hi    <= 1'b0;
        ufm_req  <= 1'b1;
        ufm_addr <= {mb_adr[13:0], 1'b0};
      end
    end else if (ufm_done) begin
      if (!uf_hi) begin
        uf_lo    <= ufm_data;
        uf_hi    <= 1'b1;
        ufm_req  <= 1'b1;
        ufm_addr <= {mb_adr[13:0], 1'b1};
      end else begin
        uf_rdata <= {ufm_data, uf_lo};
        uf_busy  <= 1'b0;
        uf_ack   <= 1'b1;
      end
    end
  end

  ufm user_flash (
    .clk(cpu_clk),
    .rst(~rst_n),
    .req(ufm_req),
    .addr(ufm_addr),
    .busy(ufm_busy),
    .done(ufm_done),
    .data(ufm_data)
  );

  // PSRAM bridge
  wire        br_ack;
  wire [63:0] br_dat_r;
  wire        line_req_toggle, line_write, line_ack_toggle;
  wire [17:0] line_addr;
  wire [9:0]  vr_hr_addr;
  wire        vr_hr_read, vr_hr_write, burst_line;
  wire [63:0] hr_read_data;
  wire [63:0] line_wbuf_rdata;

  psram_bridge #(.SYNC(CPU_36MHZ)) bridge (
    .clk(cpu_clk),
    .rst_n(rst_n),
    .cyc(mb_cyc & mb_is_psram),
    .stb(mb_stb),
    .we(mb_we),
    .adr({9'd0, mb_adr[19:0]}),   // the offset in PSRAM (8 MB)
    .dat_w(mb_dat_w),
    .cti(mb_cti),
    .ack(br_ack),
    .rd_ack(br_rd_ack),
    .dat_r(br_dat_r),
    .system_clk(system_clk),
    .line_req_toggle(line_req_toggle),
    .line_write(line_write),
    .line_addr(line_addr),
    .line_ack_toggle(line_ack_toggle),
    .buf_idx(vr_hr_addr[2:0]),
    .rbuf_we(vr_hr_write & burst_line),
    .rbuf_wdata(hr_read_data),
    .wbuf_rdata(line_wbuf_rdata)
  );

  assign mb_ack_other = mb_is_psram ? (br_ack & ~br_rd_ack) : uf_ack;

  // Performance counters (free-running, read at 0x4700xx; only with
  // `define PERF_COUNTERS, since they cost about 4% of the logic): CPU cycles
  // with a data L1 / fetch L1 bus transaction open (the L1s block on
  // them, so this is close to the time spent waiting for lines), and the
  // line transfers: data refills, data write-backs, fetch refills.
  reg [31:0] perf_dl1_cycles, perf_fl1_cycles, perf_dl1_refills, perf_dl1_wbacks, perf_fl1_refills;
`ifdef PERF_COUNTERS
  wire perf_last = mb_ack & (mb_cti == 3'b111);
  always @(posedge cpu_clk) begin
    if (~rst_n) begin
      perf_dl1_cycles <= 32'd0;
      perf_fl1_cycles <= 32'd0;
      perf_dl1_refills <= 32'd0;
      perf_dl1_wbacks <= 32'd0;
      perf_fl1_refills <= 32'd0;
    end else begin
      if (dl1_cyc) perf_dl1_cycles <= perf_dl1_cycles + 32'd1;
      if (fl1_cyc) perf_fl1_cycles <= perf_fl1_cycles + 32'd1;
      if (perf_last & mb_sel_dl1 & ~mb_we) perf_dl1_refills <= perf_dl1_refills + 32'd1;
      if (perf_last & mb_sel_dl1 & mb_we) perf_dl1_wbacks <= perf_dl1_wbacks + 32'd1;
      if (perf_last & ~mb_sel_dl1) perf_fl1_refills <= perf_fl1_refills + 32'd1;
    end
  end
`else
  always @(*) begin
    perf_dl1_cycles = 32'd0;
    perf_fl1_cycles = 32'd0;
    perf_dl1_refills = 32'd0;
    perf_dl1_wbacks = 32'd0;
    perf_fl1_refills = 32'd0;
  end
`endif
  assign mbus_dat_r = mb_is_psram ? br_dat_r : uf_rdata;

  // -------------------------------------------------------------------
  // CLOCK_CNT (0x44000C): counts cpu_clk cycles (36 MHz).
  // -------------------------------------------------------------------
  reg  [31:0] clock_cnt;
  always @(posedge cpu_clk) begin
    if (~rst_n) clock_cnt <= 32'd0;
    else        clock_cnt <= clock_cnt + 32'd1;
  end

  // -------------------------------------------------------------------
  // I/O bus (32-bit, cacheless data bus only)
  // -------------------------------------------------------------------
  // Every register answers one cycle after the request (reads are sampled
  // in the ack cycle, when the address is still stable). The mem_*
  // signals are single-cycle strobes in the request cycle.
  // Except SPI_STREAM/SPI_LAST reads, which wait for the SPI transfer.
  reg  io_ack;
  wire io_req = dio_cyc & dio_stb & ~io_ack;
  wire io_wait;
  always @(posedge cpu_clk) io_ack <= rst_n & io_req & ~io_wait;
  assign dio_ack = io_ack;

  wire [31:0] mem_addr  = {8'd0, dio_adr, 2'b00};   // 0x400000 + 0x10000 device + offset
  wire [31:0] mem_wdata = dio_dat_w;
  wire [3:0]  mem_wmask = (io_req & dio_we) ? dio_sel : 4'b0000;
  wire        mem_rstrb = io_req & ~dio_we;
  wire        mem_write = |mem_wmask;

  wire is_uart  = mem_addr[19:16] == 4'h1;
  wire is_vram  = mem_addr[19:16] == 4'h2;
  wire is_ctrl  = mem_addr[19:16] == 4'h3;
  wire is_video = mem_addr[19:16] == 4'h4;
  wire is_spi   = mem_addr[19:16] == 4'h5;
  wire is_perf  = mem_addr[19:16] == 4'h7;
  wire [31:0] perf_rdata = mem_addr[4:2] == 3'd0 ? perf_dl1_cycles :
                           mem_addr[4:2] == 3'd1 ? perf_fl1_cycles :
                           mem_addr[4:2] == 3'd2 ? perf_dl1_refills :
                           mem_addr[4:2] == 3'd3 ? perf_dl1_wbacks :
                                                   perf_fl1_refills;

  // SPI: one master. SCLK and MOSI go to the flash only while it is
  // selected, and to the SD card otherwise (an unselected card ignores
  // them, and needs >= 74 clocks with CS high before CMD0); MISO comes
  // from the selected device.
  reg  [1:0]  spi_cs;
  reg         spi_flash_oe;
  reg  [7:0]  spi_div;
  reg         spi_fast;   // SD High Speed: SCLK = cpu_clk (36 MHz), see below
  reg         spi_fast_inv;          // fast SCLK high in the first half instead
  reg  [1:0]  spi_fast_sample;       // see spi.v
  wire [31:0] spi_rx;
  wire        spi_busy, spi_sclk, spi_mosi, spi_bit_on;
  wire        spi_miso = spi_cs[0] ? flash_miso : sd_miso;
  // SPI_STREAM (0x0C) and SPI_LAST (0x1C) reads wait until the transfer is
  // done and return its 32 bits (first byte in 7:0); SPI_STREAM then starts
  // the next one (as does a write to it), so the SPI never idles in a loop
  // of reads. The word is latched at that point, as rx starts shifting.
  wire        spi_is_stream = is_spi & (mem_addr[3:2] == 2'd3);
  wire        spi_stream_rd = spi_is_stream & mem_rstrb;
  wire        spi_stream_go = spi_stream_rd & ~spi_busy;
  wire        spi_start_wide = (spi_stream_go & ~mem_addr[4]) | (spi_is_stream & mem_write);
  wire        spi_start = (is_spi & mem_write & (mem_addr[3:2] == 2'd0)) | spi_start_wide;
  assign      io_wait = spi_stream_rd & spi_busy;
  reg  [31:0] spi_word;
  always @(posedge cpu_clk)
    if (spi_stream_go) spi_word <= {spi_rx[7:0], spi_rx[15:8], spi_rx[23:16], spi_rx[31:24]};
  wire [7:0]  spi_tx = mem_wdata[7:0];
  always @(posedge cpu_clk) begin
    if (~rst_n) begin
      spi_cs  <= 2'b00;
      spi_flash_oe <= 1'b0;
      spi_div <= 8'd44;   // 400 kHz at 36 MHz
      spi_fast <= 1'b0;
      spi_fast_inv <= 1'b0;
      spi_fast_sample <= 2'd0;
    end else if (is_spi & mem_write) begin
      if (mem_addr[3:2] == 2'd1) begin
        spi_cs  <= mem_wdata[1:0];
        spi_flash_oe <= mem_wdata[4];
      end
      if (mem_addr[3:2] == 2'd2) begin
        spi_div <= mem_wdata[7:0];
        spi_fast <= mem_wdata[8] & (CPU_36MHZ != 0);
        spi_fast_inv <= mem_wdata[9];
        spi_fast_sample <= mem_wdata[11:10];
      end
    end
  end
  spi_master spi (
    .clk(cpu_clk),
    .rst(~rst_n),
    .div(spi_div),
    .fast(spi_fast),
    .fast_sample(spi_fast_sample),
    .miso_mid(spi_miso_mid),
    .start(spi_start),
    .wide(spi_start_wide),
    .tx(spi_tx),
    .rx(spi_rx),
    .busy(spi_busy),
    .sclk(spi_sclk),
    .bit_on(spi_bit_on),
    .mosi(spi_mosi),
    .miso(spi_miso)
  );
  // The flash is on the FPGA's MSPI configuration pins: they are only
  // driven while firmware enables them (SPI_CTRL bit 4), and float (pulled
  // up in top.cst) otherwise: flash programming over JTAG failed while a
  // design was driving them. While enabled, CS is driven high between
  // commands (the pull-up alone is too slow for the flash to see it).
  assign flash_cs_n = spi_flash_oe ? ~spi_cs[0] : 1'bz;
  assign flash_clk  = spi_flash_oe ? (spi_sclk & spi_cs[0]) : 1'bz;
  assign flash_mosi = spi_flash_oe ? spi_mosi : 1'bz;
  assign sd_cs_n    = ~spi_cs[1];
  // SD High Speed clock (SPI_DIV bit 8; only with the 36 MHz CPU clock):
  // system_clk is twice cpu_clk and in phase with it, so a system_clk flop
  // can put out one SCLK period per cpu_clk cycle: low in the cycle's first
  // half, high in its second (while the master's bit_on is set). spi_ph
  // toggles every cpu_clk cycle; sampled on system_clk, it still equals
  // spi_ph just before a cpu_clk edge (the second half is ending) and
  // differs from it just before the mid-cycle edge.
  // SPI_DIV bit 9 swaps the halves, bits 11:10 pick where MISO is sampled
  // (spi.v; spi_miso_mid is MISO taken at the mid-cycle system_clk edge).
  reg spi_ph = 1'b0, spi_ph_s = 1'b0, sclk_fast = 1'b0, spi_miso_mid = 1'b1;
  always @(posedge cpu_clk) spi_ph <= ~spi_ph;
  always @(posedge system_clk) begin
    spi_ph_s  <= spi_ph;
    sclk_fast <= ((spi_ph_s != spi_ph) ^ spi_fast_inv) & spi_bit_on & (CPU_36MHZ != 0);
    if (spi_ph_s != spi_ph) spi_miso_mid <= spi_miso;
  end
  // (in either mode the other clock stays low, so the OR doesn't glitch)
  assign sd_clk     = spi_cs[0] ? 1'b0 : (spi_sclk | sclk_fast);
  assign sd_mosi    = spi_mosi;
  wire [31:0] spi_rdata = mem_addr[3:2] == 2'd0 ? {24'd0, spi_rx[7:0]} :
                          mem_addr[3:2] == 2'd1 ? {23'd0, spi_busy, 3'd0, spi_flash_oe, 2'd0, spi_cs} :
                          mem_addr[3:2] == 2'd2 ? {20'd0, spi_fast_sample, spi_fast_inv, spi_fast, spi_div} :
                                                  spi_word;

  wire uart_sel_data = is_uart & (mem_addr[3:2] == 2'b00);
  wire uart_sel_stat = is_uart & (mem_addr[3:2] == 2'b01);
  wire uart_sel_div  = is_uart & (mem_addr[3:2] == 2'b10);
  wire [7:0]  uart_rx_data;
  wire        uart_rx_valid, uart_tx_busy, uart_rx_overrun;
  wire [15:0] uart_div;

  uart UART (
      .clk(cpu_clk),
      .rst_n(rst_n),
      .rx(rxd),
      .tx(txd),
      .tx_wr(uart_sel_data & mem_write),
      .tx_data(mem_wdata[7:0]),
      .rx_rd(uart_sel_data & mem_rstrb),
      .div_wr(uart_sel_div & mem_write),
      .div_data(mem_wdata[15:0]),
      .ovr_clr(uart_sel_stat & mem_write & mem_wdata[2]),
      .rx_data(uart_rx_data),
      .rx_valid(uart_rx_valid),
      .tx_busy(uart_tx_busy),
      .rx_overrun(uart_rx_overrun),
      .div(uart_div),
      .reset_req(uart_reset)
  );

  wire [31:0] uart_rdata = uart_sel_data ? {22'b0, uart_tx_busy, uart_rx_valid, uart_rx_data} :
                           uart_sel_stat ? {29'b0, uart_rx_overrun, uart_rx_valid, uart_tx_busy} :
                           uart_sel_div  ? {16'b0, uart_div} :
                                           32'b0;

  wire [31:0] video_rdata = (mem_addr[3:2] == 2'b00) ? {20'b0, x_cnt} :
                            (mem_addr[3:2] == 2'b01) ? {22'b0, y_cnt} :
                            (mem_addr[3:2] == 2'b10) ? frame_cnt :
                                                       clock_cnt;

  // -------------------------------------------------------------------
  // USB host, two ports: one host core for both (usb_hid_host.v,
  // nand2mario's with one engine switching between the ports) and each
  // port's registers (usb_port.v). Port n's registers are at
  // 0x460000 + 0x20 n.
  // -------------------------------------------------------------------
  wire is_usb = mem_addr[19:16] == 4'h6;
  wire [31:0] usb0_rdata, usb1_rdata;
  wire        usb0_event, usb1_event;
  // The core's 1 ms frame timer (12002 usb_clk cycles)
  reg  [13:0] usb_frame = 14'd0;
  wire        usb_sof = usb_frame == 14'd12001;
  always @(posedge usb_clk) usb_frame <= usb_sof ? 14'd0 : usb_frame + 14'd1;
  wire [9:0]  usb_rom_adr;
  wire [3:0]  usb_rom_data;
  usb_hid_host_rom usb_rom (.clk(usb_clk), .adr(usb_rom_adr), .data(usb_rom_data));
  wire [1:0]  usb_rst_n, usb_conerr;
  wire [3:0]  usb_typ;
  wire        usb_report, usb_report_port;
  wire [47:0] usb_rpt;
  wire [27:0] usb_dbg;
  usb_hid_host usb (
    .usbclk(usb_clk), .usbrst_n(usb_rst_n), .sof(usb_sof),
    .usb_dm0(usb_dm), .usb_dp0(usb_dp), .usb_dm1(usb2_dm), .usb_dp1(usb2_dp),
    .typ(usb_typ), .report(usb_report), .report_port(usb_report_port), .conerr(usb_conerr),
    .rpt(usb_rpt), .dbg_ukp(usb_dbg),
    .rom_adr(usb_rom_adr), .rom_data(usb_rom_data)
  );
  usb_port usb0 (
    .cpu_clk(cpu_clk), .rst_n(rst_n), .usb_clk(usb_clk),
    .reg_sel(mem_addr[4:2]), .reg_write(is_usb & mem_write & ~mem_addr[5]),
    .wdata(mem_wdata), .rdata(usb0_rdata), .report_event(usb0_event),
    .usb_rst_n(usb_rst_n[0]), .typ(usb_typ[1:0]), .conerr(usb_conerr[0]),
    .report(usb_report & ~usb_report_port), .latch(usb_rpt), .dbg(usb_dbg[13:0])
  );
  usb_port usb1 (
    .cpu_clk(cpu_clk), .rst_n(rst_n), .usb_clk(usb_clk),
    .reg_sel(mem_addr[4:2]), .reg_write(is_usb & mem_write & mem_addr[5]),
    .wdata(mem_wdata), .rdata(usb1_rdata), .report_event(usb1_event),
    .usb_rst_n(usb_rst_n[1]), .typ(usb_typ[3:2]), .conerr(usb_conerr[1]),
    .report(usb_report & usb_report_port), .latch(usb_rpt), .dbg(usb_dbg[27:14])
  );
  wire usb_report_event = usb0_event | usb1_event;
  wire [31:0] usb_rdata = mem_addr[5] ? usb1_rdata : usb0_rdata;

  // -------------------------------------------------------------------
  // Video/audio control registers (cpu_clk domain) and their crossings
  // -------------------------------------------------------------------
  reg        video_enable, audio_enable;
  reg [9:0]  video_hstart, video_hend;   // (a line is 858 pixels)
  reg [3:0]  irq_pending, irq_enable;
  reg [22:8] audio_ptr_a, audio_ptr_b;  // PSRAM offsets of 256-byte blocks
  reg        audio_ptr_a_toggle, audio_ptr_b_toggle;
  assign irq = |(irq_pending & irq_enable);

  // Interrupt events come from the video engine as toggles, synchronized
  // here; an edge sets the pending bit.
  wire [2:0] irq_event_toggle;
  reg  [2:0] irq_s1, irq_s2, irq_s3;
  always @(posedge cpu_clk) begin
    if (~rst_n) begin
      irq_s1 <= 3'b000;
      irq_s2 <= 3'b000;
      irq_s3 <= 3'b000;
    end else begin
      irq_s1 <= irq_event_toggle;
      irq_s2 <= irq_s1;
      irq_s3 <= irq_s2;
    end
  end
  wire [2:0] irq_event = irq_s2 ^ irq_s3;

  wire [2:0] ctrl_reg = mem_addr[4:2];
  always @(posedge cpu_clk) begin
    if (~rst_n) begin
      video_enable <= 1'b0;
      video_hstart <= 10'd40;
      video_hend <= 10'd680;
      audio_enable <= 1'b0;
      irq_pending <= 4'b0000;
      irq_enable <= 4'b0000;
      audio_ptr_a <= 15'd0;
      audio_ptr_b <= 15'd0;
      audio_ptr_a_toggle <= 1'b0;
      audio_ptr_b_toggle <= 1'b0;
    end else begin
      irq_pending <= irq_pending | {usb_report_event, irq_event};
      if (is_ctrl && mem_write) begin
        case (ctrl_reg)
          3'd0: video_enable <= mem_wdata[0];
          3'd1: irq_pending <= (irq_pending | {usb_report_event, irq_event}) & ~mem_wdata[3:0];
          3'd2: irq_enable <= mem_wdata[3:0];
          3'd3: audio_enable <= mem_wdata[0];
          3'd4: begin audio_ptr_a <= mem_wdata[22:8]; audio_ptr_a_toggle <= ~audio_ptr_a_toggle; end
          3'd5: begin audio_ptr_b <= mem_wdata[22:8]; audio_ptr_b_toggle <= ~audio_ptr_b_toggle; end
          3'd6: begin video_hstart <= mem_wdata[9:0]; video_hend <= mem_wdata[25:16]; end
          default: ;
        endcase
      end
    end
  end

  wire [31:0] ctrl_rdata = ctrl_reg == 3'd0 ? {31'd0, video_enable} :
                           ctrl_reg == 3'd1 ? {28'd0, irq_pending} :
                           ctrl_reg == 3'd2 ? {28'd0, irq_enable} :
                           ctrl_reg == 3'd3 ? {31'd0, audio_enable} :
                           ctrl_reg == 3'd4 ? {9'd0, audio_ptr_a, 8'd0} :
                           ctrl_reg == 3'd5 ? {9'd0, audio_ptr_b, 8'd0} :
                           ctrl_reg == 3'd6 ? {6'd0, video_hend, 6'd0, video_hstart} :
                                              32'd0;

  assign mem_rdata = is_uart  ? uart_rdata :
                     is_ctrl  ? ctrl_rdata :
                     is_video ? video_rdata :
                     is_spi   ? spi_rdata :
                     is_usb   ? usb_rdata :
                     is_perf  ? perf_rdata :
                                32'b0;

  // To the pixel clock: levels through two flops, pointer writes as
  // toggles (the pointer values are stable by the time a toggle arrives).
  reg [3:0] cfg_s1, cfg_s2;
  reg [1:0] ptr_s3;
  always @(posedge pixel_clk) begin
    cfg_s1 <= {audio_ptr_b_toggle, audio_ptr_a_toggle, audio_enable, video_enable};
    cfg_s2 <= cfg_s1;
    ptr_s3 <= cfg_s2[3:2];
  end
  wire video_enable_pix = cfg_s2[0];
  wire audio_enable_pix = cfg_s2[1];
  wire audio_refill_a = cfg_s2[2] ^ ptr_s3[0];
  wire audio_refill_b = cfg_s2[3] ^ ptr_s3[1];
  // The 2x window goes straight to the video engine, unsynchronized (the
  // clock groups are asynchronous in top.sdc, so it isn't timed): it is
  // static while in use, and a change mid-frame can only upset a line.

  // -------------------------------------------------------------------
  // Video RAM: CPU writes (cpu_clk), video engine reads (pixel_clk).
  // -------------------------------------------------------------------
  wire [10:0] vram_raddr;
  wire [31:0] vram_rdata;

  vram video_ram (
    .wclk(cpu_clk),
    .we(is_vram & mem_write & (mem_addr[12:2] < 11'd1536)),
    .waddr(mem_addr[12:2]),
    .wdata(mem_wdata),
    .rclk(pixel_clk),
    .raddr(vram_raddr),
    .rdata(vram_rdata)
  );

  // -------------------------------------------------------------------
  // PSRAM controller, hr_ram and the video/audio engine
  // -------------------------------------------------------------------
  // The GW1NR-9 has two PSRAM dies with separate pins; the controller
  // drives both in lockstep and moves 64 bits per system_clk cycle, 32 per
  // die: 64-bit word b of a burst is 32-bit words 2b (die 0) and 2b+1
  // (die 1) of the interleaved space, as the CPU sees it at 0x800000.
  //
  // hr_ram holds the video line buffers and audio sample halves: port B
  // is written by the controller's DMA, port A read by the video engine.
  // The controller's vr_* port uses the bridge's line buffers instead of
  // hr_ram for cache line transfers (burst_line).
  wire        dma_start, dma_busy;
  wire [15:0] dma_psram_block;
  wire [4:0]  dma_hr_block, dma_count;

  // DMA handshake across pixel_clk -> system_clk: the engine's one-cycle
  // dma_start becomes a toggle, turned back into a pulse on system_clk;
  // dma_busy goes back through two flops. The block parameters are held
  // by the engine from one start until the next (and it waits for busy to
  // rise and fall in between), so they are stable when the controller
  // takes them, a few system_clk cycles after the toggle.
  reg         dma_req_toggle;
  always @(posedge pixel_clk) begin
    if (pix_rst) dma_req_toggle <= 1'b0;
    else if (dma_start) dma_req_toggle <= ~dma_req_toggle;
  end
  reg  [2:0]  dma_req_s = 3'b000;
  always @(posedge system_clk) dma_req_s <= {dma_req_s[1:0], dma_req_toggle};
  wire        dma_start_ctl = dma_req_s[2] ^ dma_req_s[1];
  reg  [1:0]  dma_busy_s = 2'b00;
  always @(posedge pixel_clk) dma_busy_s <= {dma_busy_s[0], dma_busy};
  wire        dma_busy_pix = dma_busy_s[1];

  // The controller's reset, released synchronously to its clock.
  reg  [1:0]  rst_ctl_s;
  always @(posedge system_clk or negedge rst_n) begin
    if (~rst_n) rst_ctl_s <= 2'b00;
    else rst_ctl_s <= {rst_ctl_s[0], 1'b1};
  end
  wire        rst_n_ctl = rst_ctl_s[1];
  wire [10:0] hr_raddr;
  wire [31:0] hr_rdata;
  wire [63:0] hr_ram_doutb;
  wire [63:0] vr_read_data = burst_line ? line_wbuf_rdata : hr_ram_doutb;
  wire        irq_vblank, irq_audio_a, irq_audio_b;

  dpb_8k32_64 hr_ram(
      .douta(hr_rdata), //output [31:0] douta
      .doutb(hr_ram_doutb), //output [63:0] doutb
      .clka(pixel_clk), //input clka
      .ocea(1'b1), //input ocea
      .cea(1'b1), //input cea
      .reseta(pix_rst), //input reseta
      .wrea(1'b0), //input wrea
      .clkb(system_clk), //input clkb
      .oceb(1'b1), //input oceb
      .ceb(1'b1), //input ceb
      .resetb(1'b0), //input resetb
      .wreb(vr_hr_write & ~burst_line), //input wreb
      .ada(hr_raddr), //input [10:0] ada
      .dina(32'd0), //input [31:0] dina
      .adb(vr_hr_addr), //input [9:0] adb
      .dinb(hr_read_data) //input [63:0] dinb
  );

  video_engine video (
    .clk(pixel_clk),
    .rst(pix_rst),
    .cx(x_cnt),
    .cy(y_cnt),
    .cy_next(y_cnt_next),
    .video_enable(video_enable_pix),
    .hstart({2'b00, video_hstart}),
    .hend({2'b00, video_hend}),
    .audio_enable(audio_enable_pix),
    .audio_refill_a(audio_refill_a),
    .audio_refill_b(audio_refill_b),
    .audio_block_a(audio_ptr_a),
    .audio_block_b(audio_ptr_b),
    .vram_raddr(vram_raddr),
    .vram_rdata(vram_rdata),
    .hr_raddr(hr_raddr),
    .hr_rdata(hr_rdata),
    .dma_start(dma_start),
    .dma_psram_block(dma_psram_block),
    .dma_hr_block(dma_hr_block),
    .dma_count(dma_count),
    .dma_busy(dma_busy_pix),
    .rgb(rgb),
    .audio_pair(audio_pair),
    .audio_ready(audio_ready),
    .audio_used(audio_used),
    .audio_frame_counter(audio_frame_counter),
    .irq_vblank(irq_vblank),
    .irq_audio_a(irq_audio_a),
    .irq_audio_b(irq_audio_b)
  );

  // Interrupt events to the CPU domain as toggles.
  reg [2:0] irq_toggle;
  always @(posedge pixel_clk) begin
    if (pix_rst) irq_toggle <= 3'b000;
    else irq_toggle <= irq_toggle ^ {irq_audio_b, irq_audio_a, irq_vblank};
  end
  assign irq_event_toggle = irq_toggle;

  hyperram #(.LINE_SYNC(CPU_36MHZ)) hyperram_instance(
    .system_clk(system_clk),
    .memory_clk(memory_clk),
    .rst_n(rst_n_ctl),

    .dma_start(dma_start_ctl),
    .dma_psram_block(dma_psram_block),
    .dma_hr_block(dma_hr_block),
    .dma_count(dma_count),
    .dma_busy(dma_busy),

    .line_req_toggle(line_req_toggle),
    .line_write(line_write),
    .line_addr(line_addr),
    .line_ack_toggle(line_ack_toggle),
    .burst_line(burst_line),

    .vr_read(vr_hr_read),
    .vr_write(vr_hr_write),
    .vr_addr(vr_hr_addr),
    .vr_read_data(vr_read_data),
    .vr_write_data(hr_read_data),

    .O_hpram_ck(O_psram_ck),
    .O_hpram_ck_n(O_psram_ck_n),
    .IO_hpram_dq(IO_psram_dq),
    .IO_hpram_rwds(IO_psram_rwds),
    .O_hpram_cs_n(O_psram_cs_n),
    .O_hpram_reset_n(O_psram_reset_n)
  );

endmodule
