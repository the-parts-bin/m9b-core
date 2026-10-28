`timescale 1ns / 1ps

// Whole-system simulation of rtl/soc.v (VexiiRiscv, user flash, PSRAM
// bridge, PSRAM controller, video/audio engine) with one sim/psram_model.v
// per die, running sim/fw/ufm_init.hex (built from sim/fw/sim_main.c) from
// the user flash model.
// UART output is printed from the UART's write strobe; the UART's baud
// divider is shrunk with a defparam so the program doesn't wait on real
// 115200 baud timing. The video timing is a short frame (858 x 10, 6
// visible lines, set into the video engine with defparams); the firmware
// draws a one-pixel white frame, which is checked pixel by pixel (rgb at
// cycle t is the pixel at cx(t) - 1).
//
// Run with sim/run_soc.sh.
module tb;
  parameter real TCKD = 8.0;   // inside the model's passing read window

  GSR GSR (.GSRI(1'b1));   // referenced by the Gowin primitive models

  // As on the board: the CPU and video on the 27 MHz pixel clock, the
  // PSRAM controller on 72 / 144 MHz from another PLL (unrelated phase).
  reg pixel_clk = 1'b0;
  always #18.519 pixel_clk = ~pixel_clk;   // 27 MHz
  reg  cpu_clk = 1'b0;                      // 36 MHz: system_clk / 2 (see below)
  reg memory_clk = 1'b0;
  reg system_clk = 1'b0;
  initial begin
    #1.3;
    forever #3.4722 memory_clk = ~memory_clk;   // 144 MHz
  end
  always @(posedge memory_clk) system_clk <= ~system_clk;   // 72 MHz
  always @(posedge system_clk) cpu_clk <= ~cpu_clk;         // 36 MHz, synchronous

  reg rst_n = 1'b0;
  reg pix_rst = 1'b0;

  wire txd;

  // HDMI-style timing, as hdmi.sv produces it.
  localparam ACTIVE_W = 720, FRAME_W = 858, ACTIVE_H = 6, FRAME_H = 10;
  reg [11:0] cx = 0;
  reg [9:0]  cy = 0, cy_next = 1;
  always @(posedge pixel_clk) begin
    if (cx == FRAME_W - 1) begin
      cx <= 0;
      cy <= cy_next;
      cy_next <= (cy_next == FRAME_H - 1) ? 10'd0 : cy_next + 1'b1;
    end else begin
      cx <= cx + 1'b1;
    end
  end
  wire [23:0] rgb;
  wire [63:0] audio_pair;
  wire        audio_ready;
  reg         audio_used = 1'b0;
  always @(posedge pixel_clk) audio_used <= audio_ready && !audio_used;
  wire [1:0]  psram_ck, psram_ck_n, psram_cs_n, psram_reset_n;
  wire        flash_clk, flash_cs_n, flash_mosi, flash_miso;
  // USB: no device, just the pull-downs.
  reg usb_clk = 1'b0;
  always #41.667 usb_clk = ~usb_clk;   // 12 MHz
  wire usb_dm, usb_dp;
  pulldown (usb_dm); pulldown (usb_dp);
  pullup (flash_clk); pullup (flash_cs_n); pullup (flash_mosi); pullup (flash_miso);   // as in top.cst
  // SD card: with SD_MODEL (run_sd.sh), sd_card_model.v behind board-like
  // pin delays (SD_OUTD to the card, SD_IND back; the card's output delay
  // is SD_TODLY, 14 ns by default, the SD maximum); else MISO idles high.
  wire sd_clk, sd_cs_n, sd_mosi, sd_miso;
`ifdef SD_MODEL
`ifndef SD_TODLY
`define SD_TODLY 14.0
`endif
`ifndef SD_OUTD
`define SD_OUTD 6.0
`endif
`ifndef SD_IND
`define SD_IND 4.0
`endif
  wire sd_clk_c, sd_cs_n_c, sd_mosi_c, sd_miso_c;
  assign #(`SD_OUTD) sd_clk_c = sd_clk;
  assign #(`SD_OUTD) sd_cs_n_c = sd_cs_n;
  assign #(`SD_OUTD) sd_mosi_c = sd_mosi;
  assign #(`SD_IND) sd_miso = sd_miso_c;
  pullup (sd_miso_c);
  sd_card_model #(.TODLY(`SD_TODLY)) sd (.sclk(sd_clk_c), .cs_n(sd_cs_n_c), .mosi(sd_mosi_c), .miso(sd_miso_c));
`else
  assign sd_miso = 1'b1;
`endif
  spi_flash_model spi_flash (.sclk(flash_clk), .cs_n(flash_cs_n), .mosi(flash_mosi), .miso(flash_miso));
  wire [15:0] psram_dq;
  wire [1:0]  psram_rwds;

  soc dut (
    .cpu_clk(cpu_clk),
    .rst_n(rst_n),
    .pixel_clk(pixel_clk),
    .pix_rst(pix_rst),
    .system_clk(system_clk),
    .memory_clk(memory_clk),
    .rxd(1'b1),
    .txd(txd),
    .x_cnt(cx),
    .y_cnt(cy),
    .y_cnt_next(cy_next),
    .frame_cnt(32'd0),
    .rgb(rgb),
    .audio_pair(audio_pair),
    .audio_ready(audio_ready),
    .audio_used(audio_used),
    .audio_frame_counter(),
    .flash_clk(flash_clk),
    .flash_cs_n(flash_cs_n),
    .flash_mosi(flash_mosi),
    .flash_miso(flash_miso),
    .usb_clk(usb_clk),
    .usb_dm(usb_dm),
    .usb_dp(usb_dp),
    .sd_clk(sd_clk),
    .sd_cs_n(sd_cs_n),
    .sd_mosi(sd_mosi),
    .sd_miso(sd_miso),
    .O_psram_ck(psram_ck),
    .O_psram_ck_n(psram_ck_n),
    .IO_psram_rwds(psram_rwds),
    .IO_psram_dq(psram_dq),
    .O_psram_reset_n(psram_reset_n),
    .O_psram_cs_n(psram_cs_n)
  );
  // Fast UART (the divider register, 8 clocks per bit) so the program
  // doesn't wait on real 115200 baud timing.
  initial force dut.UART.div = 16'd8;
  defparam dut.video.ACTIVE_H = ACTIVE_H;
  defparam dut.video.FRAME_H = FRAME_H;

  // Frame checker: once video is on and a whole frame has been fetched,
  // every visible pixel must be white on rows 0 and ACTIVE_H - 1 and at
  // columns 0 and ACTIVE_W - 1, black elsewhere; everything else black.
  integer frames_on = 0, pix_checked = 0, pix_errors = 0;
  reg [11:0] px;
  reg [23:0] want;
  always @(posedge pixel_clk) begin
    if (cx == 0 && cy == 0 && dut.video_enable_pix) frames_on = frames_on + 1;
    if (frames_on >= 2) begin
      if (cx >= 1 && cx <= ACTIVE_W && cy < ACTIVE_H) begin
        px = cx - 1;
        want = (cy == 0 || cy == ACTIVE_H - 1 || px == 0 || px == ACTIVE_W - 1) ? 24'hFFFFFF : 24'h000000;
        pix_checked = pix_checked + 1;
      end else begin
        want = 24'h000000;
      end
      if (rgb !== want && !(cx == 0 && cy == 0)) begin
        pix_errors = pix_errors + 1;
        if (pix_errors <= 8) $display("  pixel at cx %0d cy %0d: %h, expected %h", cx, cy, rgb, want);
      end
    end
  end

`include "vexii_mem_init.vh"

  psram_model #(.TCKD(TCKD)) psram0 (
    .ck(psram_ck[0]), .ck_n(psram_ck_n[0]), .cs_n(psram_cs_n[0]),
    .reset_n(psram_reset_n[0]), .dq(psram_dq[7:0]), .rwds(psram_rwds[0])
  );
  psram_model #(.TCKD(TCKD)) psram1 (
    .ck(psram_ck[1]), .ck_n(psram_ck_n[1]), .cs_n(psram_cs_n[1]),
    .reset_n(psram_reset_n[1]), .dq(psram_dq[15:8]), .rwds(psram_rwds[1])
  );

  // UART output, one line at a time; stop on "done".
  reg [8*160-1:0] line = 0;
  always @(posedge cpu_clk) begin
    if (dut.UART.tx_wr && dut.UART.tx_left == 4'd0) begin
      if (dut.UART.tx_data == 8'h0a) begin
        $display("%t uart: %0s", $realtime, line);
        if (line[8*4-1:0] == "done") begin
          $display("line transfers: %0d refills, %0d write-backs", refills, writebacks);
`ifdef SD_MODEL
          $display("sd model: %0d commands, %0d MOSI setup errors", sd.commands, sd.setup_errors);
`endif
          $display("video: %s, %0d visible pixels checked over %0d frames, %0d errors",
                   (pix_errors == 0 && pix_checked > 0) ? "PASS" : "FAIL", pix_checked, frames_on - 1, pix_errors);
          $finish;
        end
        line = 0;
      end else begin
        line = {line[8*159-1:0], dut.UART.tx_data};
      end
    end
  end

  // Count cache line transfers through the bridge.
  integer refills = 0, writebacks = 0;
  reg prev_req = 1'b0;
  always @(posedge cpu_clk) begin
    if (dut.bridge.line_req_toggle != prev_req) begin
      if (dut.bridge.line_write) writebacks = writebacks + 1;
      else                       refills    = refills + 1;
    end
    prev_req <= dut.bridge.line_req_toggle;
  end

  // Miss trace: every step of the data L1 line transfers for PSRAM lines
  // 0x28000 .. 0x283FF (sim_main.c's miss test), in CPU cycles since the
  // CPU's request, until the CPU's next I/O access (its CLOCK_CNT read).
  integer cc = 0, t_req = 0, beats = 0, rwords = 0;
  reg tr = 1'b0, p_fl1 = 1'b0, p_dl1 = 1'b0, p_lrt = 1'b0, p_lat = 1'b0, p_cs = 1'b1, p_dio = 1'b0, p_busy = 1'b0;
  // the traced lines, or (once they have started) the dirty victims at
  // 0x14100 .. 0x142FF that go out first
  reg armed = 1'b0;
  wire tr_line = (dut.dl1_adr[19:3] >= 17'hA00 && dut.dl1_adr[19:3] < 17'hA10) ||   // PSRAM lines
                 (armed && dut.dl1_adr[19:3] >= 17'h504 && dut.dl1_adr[19:3] < 17'h50C);
  always @(posedge cpu_clk) if (dut.dl1_cyc && dut.dl1_adr[19:3] == 17'hA00) armed <= 1'b1;
  task ev(input [8*40-1:0] what);
    $display("  miss +%0d cpu cycles (%0t): %0s", cc - t_req, $realtime, what);
  endtask
  always @(posedge system_clk) begin
    // on system_clk to see the controller's steps (cc counts cpu cycles)
    if (tr) begin
      if (dut.bridge.line_req_toggle != p_lrt) ev(dut.bridge.line_write ? "bridge: write-back request out" : "bridge: refill request out");
      if (dut.hyperram_instance.line_busy && !p_busy) ev("ctrl: accepted");
      if (psram_cs_n[0] != p_cs) ev(psram_cs_n[0] ? "ctrl: CS# high" : "ctrl: CS# low");
      if (dut.bridge.rbuf_we) begin
        if (rwords == 0) ev("ctrl: first refill word into rbuf");
        if (rwords == 7) ev("ctrl: last refill word into rbuf");
        rwords = rwords + 1;
      end
      if (dut.hyperram_instance.line_ack_toggle != p_lat) ev("ctrl: ack toggled");
    end
    p_lrt <= dut.bridge.line_req_toggle;
    p_busy <= dut.hyperram_instance.line_busy;
    p_cs <= psram_cs_n[0];
    p_lat <= dut.hyperram_instance.line_ack_toggle;
  end
  always @(posedge cpu_clk) begin
    cc = cc + 1;
    if (dut.dl1_cyc && !p_dl1 && tr_line) begin
      if (!tr) begin
        tr = 1'b1; t_req = cc; rwords = 0;
        $display("miss trace: line %h", {dut.dl1_adr[20:3], 6'b0});
      end
      ev(dut.dl1_we ? "cpu: dl1 write-back cycle starts" : "cpu: dl1 refill cycle starts");
      beats = 0;
    end
    if (tr && dut.dl1_ack) begin
      if (beats == 0) ev("bridge: first beat acked to cpu");
      beats = beats + 1;
      if (dut.dl1_cti == 3'b111) ev("bridge: last beat acked to cpu");
    end
    if (tr && !dut.dl1_cyc && p_dl1) ev("cpu: dl1 cycle ends");
    if (tr && dut.dio_cyc && !p_dio) begin
      ev("cpu: next I/O access (CLOCK_CNT)");
      tr = 1'b0;
    end
    if (tr && dut.fl1_cyc && !p_fl1) ev("cpu: fetch L1 refill cycle starts");
    if (tr && !dut.fl1_cyc && p_fl1) ev("cpu: fetch L1 refill cycle ends");
    p_fl1 <= dut.fl1_cyc;
    p_dl1 <= dut.dl1_cyc;
    p_dio <= dut.dio_cyc;
  end

  // The program: ufm_init.hex (sim/fw) into the user flash model.
  reg [31:0] ufm_image [0:19455];
  integer ufm_i;
  initial begin
    $readmemh("ufm_init.hex", ufm_image);
    for (ufm_i = 0; ufm_i < 19456; ufm_i = ufm_i + 1)
      dut.user_flash.flash.MEM_DATA[ufm_i / 64][ufm_i % 64] = ufm_image[ufm_i];
  end

  initial begin
    if ($test$plusargs("fst")) begin
      $dumpfile("soc.fst");
      $dumpvars(0, tb);
    end
    repeat (20) @(posedge cpu_clk);
    rst_n = 1'b1;
    // pix_rst: a clean pulse on the pixel clock (on the board it's rst_pix);
    // non-blocking so the design sees it.
    repeat (4) @(posedge pixel_clk);
    pix_rst <= 1'b1;
    repeat (4) @(posedge pixel_clk);
    pix_rst <= 1'b0;
  end

  initial begin
    #40000000;
    $display("TIMEOUT");
    $finish;
  end
endmodule
