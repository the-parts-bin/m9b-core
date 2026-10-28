`timescale 1ns / 1ps

// Simulates rtl/hyperram.sv against sim/psram_model.v (one per die), using
// Gowin's primitive models (OSER4/IDES4/IODELAY/IOBUF):
//   - the controller's CR0 write after reset (both dies must end up with
//     CR0 = 0x8f1c),
//   - DMA: PSRAM contents are preloaded through the models (interleaved:
//     even 32-bit words on die 0, odd on die 1), copied into hr_ram with
//     DMA requests, and compared.
// Cache line transfers are covered by the whole-system sim (tb_soc.v).
//
// TCKD (PSRAM clock-to-output delay on reads) is set at compile time with
// -Ptb.TCKD=<ns> (see run.sh).
module tb;
  parameter real TCKD = 3.0;

  GSR GSR (.GSRI(1'b1));   // referenced by the Gowin primitive models

  // Clocks, as produced by pll_main: memory_clk = 148.5 MHz,
  // system_clk = memory_clk / 2 with rising edges aligned.
  reg memory_clk = 1'b0;
  reg system_clk = 1'b0;
  always #3.367 memory_clk = ~memory_clk;
  always #6.734 system_clk = ~system_clk;

  reg rst_n = 1'b0;

  // DMA port
  reg         dma_start = 1'b0;
  reg  [15:0] dma_psram_block = 16'd0;
  reg  [4:0]  dma_hr_block = 5'd0;
  reg  [4:0]  dma_count = 5'd0;
  wire        dma_busy;

  // hr_ram port B (dpb_8k32_64: registered read, READ_MODE 0). 64-bit
  // word b is CPU-view words 2b (bits 31:0) and 2b+1 (bits 63:32).
  wire        vr_read, vr_write, burst_line;
  wire [9:0]  vr_addr;
  reg  [63:0] vr_read_data;
  wire [63:0] vr_write_data;
  reg  [31:0] hr_ram [0:2047];
  always @(posedge system_clk) begin
    vr_read_data <= {hr_ram[2 * vr_addr + 1], hr_ram[2 * vr_addr]};
    if (vr_write && !burst_line) begin
      hr_ram[2 * vr_addr]     <= vr_write_data[31:0];
      hr_ram[2 * vr_addr + 1] <= vr_write_data[63:32];
    end
  end

  // PSRAM pins.
  wire [1:0]  psram_ck, psram_ck_n, psram_cs_n, psram_reset_n;
  wire [15:0] psram_dq;
  wire [1:0]  psram_rwds;

  hyperram dut (
    .system_clk(system_clk),
    .memory_clk(memory_clk),
    .rst_n(rst_n),
    .dma_start(dma_start),
    .dma_psram_block(dma_psram_block),
    .dma_hr_block(dma_hr_block),
    .dma_count(dma_count),
    .dma_busy(dma_busy),
    .line_req_toggle(1'b0),
    .line_write(1'b0),
    .line_addr(18'd0),
    .line_ack_toggle(),
    .burst_line(burst_line),
    .vr_read(vr_read),
    .vr_write(vr_write),
    .vr_addr(vr_addr),
    .vr_read_data(vr_read_data),
    .vr_write_data(vr_write_data),
    .O_hpram_ck(psram_ck),
    .O_hpram_ck_n(psram_ck_n),
    .O_hpram_cs_n(psram_cs_n),
    .O_hpram_reset_n(psram_reset_n),
    .IO_hpram_dq(psram_dq),
    .IO_hpram_rwds(psram_rwds)
  );

  psram_model #(.TCKD(TCKD)) psram (
    .ck(psram_ck[0]), .ck_n(psram_ck_n[0]), .cs_n(psram_cs_n[0]),
    .reset_n(psram_reset_n[0]), .dq(psram_dq[7:0]), .rwds(psram_rwds[0])
  );
  psram_model #(.TCKD(TCKD)) psram1 (
    .ck(psram_ck[1]), .ck_n(psram_ck_n[1]), .cs_n(psram_cs_n[1]),
    .reset_n(psram_reset_n[1]), .dq(psram_dq[15:8]), .rwds(psram_rwds[1])
  );

  // PSRAM content as the CPU sees it: 32-bit word w of the interleaved
  // space holds pattern(w). Word w is on die w & 1, as die word w >> 1;
  // each die word is two half-words, the first byte on the bus (lower
  // address) in bits 15:8.
  function [31:0] pattern(input integer w);
    pattern = w * 32'h9E3779B1 + 32'h7F4A7C15;
  endfunction

  integer i, w, errors;
  reg [31:0] p;

  task dma(input [15:0] psram_block, input [4:0] hr_block, input [4:0] count);
    begin
      @(posedge system_clk);
      dma_psram_block <= psram_block;
      dma_hr_block <= hr_block;
      dma_count <= count;
      dma_start <= 1'b1;
      @(posedge system_clk);
      dma_start <= 1'b0;
      @(posedge system_clk);
      while (dma_busy) @(posedge system_clk);
    end
  endtask

  task check(input [8*24-1:0] label, input [15:0] psram_block, input [4:0] hr_block, input [4:0] count);
    begin
      errors = 0;
      for (i = 0; i < count * 64; i = i + 1)
        if (hr_ram[hr_block * 64 + i] !== pattern(psram_block * 64 + i)) begin
          errors = errors + 1;
          if (errors <= 4)
            $display("  hr_ram[%0d] = %h, expected %h", hr_block * 64 + i,
                     hr_ram[hr_block * 64 + i], pattern(psram_block * 64 + i));
        end
      $display("TCKD=%0.2f ns: %0s %s (%0d/%0d words wrong)", TCKD, label,
               errors ? "FAIL" : "PASS", errors, count * 64);
    end
  endtask

  initial begin
    $dumpfile("hyperram.fst");
    $dumpvars(0, tb);

    for (i = 0; i < 2048; i = i + 1) hr_ram[i] = 32'hCCCCCCCC;
    // Preload the first 64 KB (32 KB per die) after the models' own init.
    #1;
    for (w = 0; w < 16384; w = w + 1) begin
      p = pattern(w);
      if (w & 1) begin
        psram1.mem[(w >> 1) * 2]     = {p[7:0], p[15:8]};
        psram1.mem[(w >> 1) * 2 + 1] = {p[23:16], p[31:24]};
      end else begin
        psram.mem[(w >> 1) * 2]      = {p[7:0], p[15:8]};
        psram.mem[(w >> 1) * 2 + 1]  = {p[23:16], p[31:24]};
      end
    end

    repeat (10) @(posedge system_clk);
    rst_n = 1'b1;
    // The controller waits 16384 cycles (tVCS) before writing CR0.
    repeat (16384 + 100) @(posedge system_clk);
    $display("CR0 after reset: die 0 %h, die 1 %h (want 8f1c)", psram.cr0, psram1.cr0);

    dma(16'd2, 5'd5, 5'd3);      // PSRAM blocks 2..4 -> hr_ram blocks 5..7
    check("3-block DMA", 16'd2, 5'd5, 5'd3);

    dma(16'd100, 5'd20, 5'd11);  // a video line's worth
    check("11-block DMA", 16'd100, 5'd20, 5'd11);
    $finish;
  end

  initial begin
    #800000;
    $display("TIMEOUT");
    $finish;
  end
endmodule
