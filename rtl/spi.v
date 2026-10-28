// SPI master, mode 0 (clock idles low, data sampled on the rising edge),
// MSB first, 8 bits per start, or 32 (wide) with MOSI high. SCLK = clk /
// (2 * (div + 1)): 18 MHz at div 0 on the 36 MHz CPU clock, and div 44
// (the reset value) gives the SD card's 400 kHz for its initialization.
//
// Timing, in clk cycles of the divided half-period: the first bit is on
// MOSI from start; at each rising SCLK edge MISO is sampled (it was set
// by the slave on the previous falling edge, half a period earlier), at
// each falling edge the next bit goes out. busy drops after the last
// falling edge, so SCLK is low again when the next transfer (or CS)
// changes. rx holds the last 32 bits received (the last byte in 7:0).
//
// fast (SD High Speed, SCLK = clk): one bit per clk cycle, with div
// ignored. sclk stays low; instead bit_on is high during each bit's cycle
// and soc.v makes the pin's clock from it on system_clk (= 2 x clk): low
// in the first half of the cycle, high in the second. The bit is on MOSI
// for the whole cycle (the card samples it at the rising edge, mid-cycle),
// and MISO is sampled at the end of the cycle: the card changed it at the
// previous falling edge (the start of the cycle) and holds it until the
// next one, so this is the latest safe point (27.8 ns for its output delay
// plus the I/O delays).

module spi_master (
  input  wire        clk,
  input  wire        rst,
  input  wire [7:0]  div,
  input  wire        fast,
  input  wire [1:0]  fast_sample,  // fast: 0 end of the bit's cycle, 1 its middle
                                   // (miso_mid), 2 the middle of the next cycle
  input  wire        miso_mid,     // MISO sampled by soc.v mid-cycle (system_clk)
  input  wire        start,     // one-cycle pulse, only while !busy
  input  wire        wide,      // with start: 32 bits of ones instead of tx
  input  wire [7:0]  tx,
  output reg  [31:0] rx,
  output reg         busy,
  output reg         sclk,
  output wire        bit_on,   // fast: a bit is being transferred this cycle
  output wire        mosi,
  input  wire        miso
);

  reg [7:0]  cnt;
  reg [4:0]  bits;     // bits left to sample after this one
  reg [31:0] sh;

  assign mosi = sh[31];
  reg fast_busy, fast_first, fast_tail;
  assign bit_on = fast_busy & ~fast_tail;
  wire fast_late = fast_sample == 2'd2;
  wire fast_bit  = fast_sample == 2'd0 ? miso : miso_mid;

  always @(posedge clk) begin
    if (rst) begin
      busy <= 1'b0;
      fast_busy <= 1'b0;
      fast_tail <= 1'b0;
      sclk <= 1'b0;
      sh <= 32'hFFFFFFFF;
    end else if (!busy) begin
      if (start) begin
        busy <= 1'b1;
        fast_busy <= fast;
        fast_first <= 1'b1;
        fast_tail <= 1'b0;
        sh <= wide ? 32'hFFFFFFFF : {tx, 24'hFFFFFF};
        bits <= wide ? 5'd31 : 5'd7;
        cnt <= div;
      end
    end else if (fast_busy) begin
      // One bit per cycle: sample the bit on MISO, put out the next one.
      // (Late sampling takes each bit a cycle later, and the last one in an
      // extra cycle without a clock pulse.)
      fast_first <= 1'b0;
      if (!fast_late || !fast_first) rx <= {rx[30:0], fast_bit};
      sh <= {sh[30:0], 1'b1};
      if (fast_tail || (bits == 5'd0 && !fast_late)) begin
        busy <= 1'b0;
        fast_busy <= 1'b0;
        fast_tail <= 1'b0;
      end else if (bits == 5'd0) fast_tail <= 1'b1;
      else bits <= bits - 5'd1;
    end else if (cnt != 8'd0) begin
      cnt <= cnt - 8'd1;
    end else begin
      cnt <= div;
      sclk <= ~sclk;
      if (!sclk) begin
        // Rising edge: sample.
        rx <= {rx[30:0], miso};
      end else begin
        // Falling edge: next bit out, or done.
        sh <= {sh[30:0], 1'b1};
        if (bits == 5'd0) busy <= 1'b0;
        else bits <= bits - 5'd1;
      end
    end
  end

endmodule
