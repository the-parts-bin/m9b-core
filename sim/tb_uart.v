`timescale 1ns / 1ps
// uart.v receiver: 20 bytes back to back at ~3 Mbaud (divider 9, sender 1%
// slow), read from the FIFO afterwards (16 fit, then overrun), and a
// loopback of one byte through the transmitter.
// Run: iverilog -g2012 -s tb -o uart.vvp tb_uart.v ../rtl/uart.v && vvp -n uart.vvp
module tb;
  reg clk = 0; always #18.519 clk = ~clk;   // 27 MHz
  reg rst_n = 0, rx = 1, rd = 0, div_wr = 0, tx_wr = 0;
  reg [7:0] tx_data = 0;
  wire tx, valid, busy, ovr; wire [7:0] data; wire [15:0] div;
  uart u (.clk(clk), .rst_n(rst_n), .rx(rx), .tx(tx), .tx_wr(tx_wr), .tx_data(tx_data),
    .rx_rd(rd), .div_wr(div_wr), .div_data(16'd9), .ovr_clr(1'b0),
    .rx_data(data), .rx_valid(valid), .tx_busy(busy), .rx_overrun(ovr), .div(div));
  real tbit = 9 * 37.037 * 1.01;
  task send(input [7:0] b); integer k; begin
    rx = 0; #(tbit); for (k = 0; k < 8; k = k + 1) begin rx = b[k]; #(tbit); end rx = 1; #(tbit); end endtask
  integer i, errors = 0, got = 0;
  initial begin
    repeat (4) @(posedge clk); rst_n = 1;
    @(posedge clk); div_wr = 1; @(posedge clk); div_wr = 0;
    for (i = 0; i < 20; i = i + 1) send(8'h30 + i * 7);
    #1000;
    // Drain: like the CPU, strobe, then sample in the next cycle.
    while (valid) begin
      @(posedge clk); rd <= 1; @(posedge clk); rd <= 0;
      if (data !== 8'h30 + got * 7) begin errors = errors + 1; $display("  byte %0d: %h", got, data); end
      got = got + 1;
      @(posedge clk); #1;
    end
    $display("rx: %0d bytes read (FIFO holds 16), %0d wrong, overrun %b: %s", got, errors, ovr,
             (got == 16 && errors == 0 && ovr) ? "PASS" : "FAIL");

    // A CPU polling DATA (strobe, sample next cycle, strobe again two cycles
    // later) while bytes arrive at every possible moment: each byte must be
    // read exactly once.
    got = 0; errors = 0;
    fork
      for (i = 0; i < 40; i = i + 1) begin send(8'h41 + i); #(tbit * (i % 3)); end
      begin : poll
        integer n; reg [7:0] seen [0:63];
        n = 0;
        repeat (40 * 12 * 9 + 2000) begin
          @(posedge clk); rd <= 1;
          @(posedge clk); rd <= 0;
          #1 if (valid) begin seen[n] = data; n = n + 1; end
          @(posedge clk);
        end
        for (i = 0; i < n; i = i + 1) if (seen[i] !== 8'h41 + i) errors = errors + 1;
        got = n;
      end
    join
    $display("polled: %0d bytes (want 40), %0d wrong: %s", got, errors, (got == 40 && errors == 0) ? "PASS" : "FAIL");
    $finish;
  end
endmodule
