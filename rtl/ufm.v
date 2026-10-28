// User flash (FLASH608K, 76 KB: 304 rows x 64 columns x 32 bits) read
// controller: one 32-bit word per request.
//
// Timing (UG295, FLASH64KZ timing, which FLASH608K shares): address and
// XE/YE valid >= 20 ns (Tads) before SE rises, SE high >= 5 ns, DOUT valid
// <= 25 ns (Tacc) after SE rises and held until the next read, address held
// >= 25 ns (Tah) after SE rises. At 36 MHz (27.8 ns) each step is one cycle:
//   cycle 0: address, XE, YE     cycle 2: SE low, DOUT captured (56 ns)
//   cycle 1: SE high             cycle 3: XE, YE low
// XE/YE are dropped between words as in the datasheet's read diagram (and
// as Gowin's simulation model needs: it only starts a read from idle).
//
// Word address a: XADR = a[14:6] (row; page = XADR[8:3]), YADR = a[5:0].

module ufm (
  input  wire        clk,
  input  wire        rst,
  input  wire        req,        // one-cycle pulse, only while !busy
  input  wire [14:0] addr,       // word address (0 .. 19455)
  output wire        busy,
  output reg         done,       // one-cycle pulse, data valid from here on
  output reg  [31:0] data
);

  reg [1:0]  step;
  reg        active;
  reg [8:0]  xadr;
  reg [5:0]  yadr;
  reg        xe, se;
  wire [31:0] dout;

  assign busy = active;

  always @(posedge clk) begin
    done <= 1'b0;
    if (rst) begin
      active <= 1'b0;
      step <= 2'd0;
      xe <= 1'b0;
      se <= 1'b0;
    end else if (!active) begin
      if (req) begin
        active <= 1'b1;
        step <= 2'd0;
        xadr <= addr[14:6];
        yadr <= addr[5:0];
        xe <= 1'b1;
      end
    end else begin
      step <= step + 2'd1;
      case (step)
        2'd0: se <= 1'b1;
        2'd1: se <= 1'b0;
        2'd2: begin data <= dout; xe <= 1'b0; end
        2'd3: begin active <= 1'b0; done <= 1'b1; end
      endcase
    end
  end

  // XE and YE switch together; program/erase aren't wired up.
  wire        ye = xe;
  wire        lo = 1'b0;
  wire [31:0] din = 32'd0;
  FLASH608K flash (
    .XADR(xadr), .YADR(yadr),
    .XE(xe), .YE(ye), .SE(se),
    .ERASE(lo), .PROG(lo), .NVSTR(lo),
    .DIN(din),
    .DOUT(dout)
  );

endmodule
