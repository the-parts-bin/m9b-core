`timescale 1ns / 1ps
// ufm.v against Gowin's FLASH608K model: backdoor-filled, read back-to-back
// at 27 MHz. Run with: iverilog -g2012 -s tb -o ufm.vvp tb_ufm.v ../rtl/ufm.v PRIM && vvp ufm.vvp
module tb;
  GSR GSR (.GSRI(1'b1));
  reg clk = 1'b0;
  always #18.519 clk = ~clk;
  reg rst = 1'b1, req = 1'b0;
  reg [14:0] addr = 0;
  wire busy, done;
  wire [31:0] data;
  ufm dut (.clk(clk), .rst(rst), .req(req), .addr(addr), .busy(busy), .done(done), .data(data));

  function [31:0] pat(input integer a); pat = 32'h12000034 | (a[15:0] << 8); endfunction
  integer i, x, y, errors = 0, n = 0;
  integer list [0:8];
  initial begin
    for (x = 0; x < 304; x = x + 1)
      for (y = 0; y < 64; y = y + 1)
        dut.flash.MEM_DATA[x][y] = pat(x * 64 + y);
    list[0] = 0; list[1] = 1; list[2] = 2; list[3] = 63; list[4] = 64;
    list[5] = 511; list[6] = 512; list[7] = 12345; list[8] = 19455;
    repeat (4) @(posedge clk);
    rst <= 1'b0;
    for (i = 0; i < 9; i = i + 1) begin
      @(posedge clk);
      while (busy) @(posedge clk);
      req <= 1'b1; addr <= list[i];
      @(posedge clk); req <= 1'b0;
      @(posedge done); @(negedge clk);
      n = n + 1;
      if (data !== pat(list[i])) begin
        errors = errors + 1;
        $display("  word %0d: %h, expected %h", list[i], data, pat(list[i]));
      end
    end
    // Back-to-back: 32 consecutive words, request as soon as idle.
    for (i = 100; i < 132; i = i + 1) begin
      while (busy || req) @(posedge clk);
      req <= 1'b1; addr <= i;
      @(posedge clk); req <= 1'b0;
      @(posedge done); @(negedge clk);
      n = n + 1;
      if (data !== pat(i)) begin
        errors = errors + 1;
        if (errors < 10) $display("  word %0d: %h, expected %h", i, data, pat(i));
      end
    end
    $display("ufm: %s, %0d reads, %0d errors", errors ? "FAIL" : "PASS", n, errors);
    $finish;
  end
endmodule
