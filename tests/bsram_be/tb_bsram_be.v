`timescale 1ns / 1ps
// Simulation of bsram_be.v with Gowin's DPB model: prints the UART lines.
// iverilog -g2012 -s tb -o tb.vvp tb_bsram_be.v bsram_be.v <prim_sim.v>
// (+define+BE_FAULT: block 7's port A ignores its byte enables)
module tb;
  GSR GSR (.GSRI(1'b1));
  reg clk = 1'b0;
  always #18.519 clk = ~clk;
  wire txd, txd2;
  wire [5:0] led;
  localparam DIV = 4;
  bsram_be #(.UART_DIV(DIV), .STRESS(2048)) dut (.ext_clk(clk), .reset(1'b1), .txd(txd), .txd2(txd2), .led(led));

  // UART receiver: one character per 10 bits of DIV clocks.
  integer passes = 0;
  reg [8*200-1:0] line = 0;
  integer n = 0;
  reg [31:0] first4 = 0;
  initial begin : rx
    reg [7:0] c;
    integer b;
    forever begin
      @(negedge txd);
      repeat (DIV / 2) @(posedge clk);
      for (b = 0; b < 8; b = b + 1) begin
        repeat (DIV) @(posedge clk);
        c[b] = txd;
      end
      repeat (DIV) @(posedge clk);
      if (c == 8'h0a) begin
        $display("%0s", line);
        if (first4 == "pass") passes = passes + 1;
        line = 0;
        n = 0;
        if (passes == 2) $finish;
      end else if (c != 8'h0d) begin
        line = {line[8*199-1:0], c};
        if (n < 4) first4 = {first4[23:0], c};
        n = n + 1;
      end
    end
  end
  initial begin
    #2000000000;
    $display("TIMEOUT");
    $finish;
  end
endmodule
