// NOT USED at the moment (not included by soc.v): the core is generated
// without --blackbox-byte-enables, and Gowin infers the data L1 as one
// 2048 x 8 block per byte lane (see README). Kept for reference.
//
// SpinalHDL's standard RAM blackbox (one write port, one synchronous read
// port), used by VexiiRiscv.v when generated with --blackbox-byte-enables:
// SpinalHDL then emits every memory with masked writes as an instance of
// this module instead of inferring it.
//
// 64 bits wide with 8 byte-mask bits, up to 1024 deep (the data L1 banks):
// four SDPB blocks in 16-bit mode (1024 x 16 each), block k holding bits
// 16k+15..16k, with the blocks' byte enables (ADA[1:0]) taking mask bits
// 2k+1..2k. Inferred from a byte-lane array, Gowin synthesis puts each
// byte lane in its own block instead.
//
// Byte enables are only shown in Gowin's documentation for 16-bit mode
// (UG285's SDPB example), and they misbehaved on hardware in both modes:
// a partial write with write-mask bit 0 clear still (usually) wrote lane
// 0 -- in 32-bit mode for stores to lanes 1..3, in 16-bit mode (below)
// for stores to lane 1. Only the enable fed by mask bit 0 failed, on
// whichever block it was placed; Gowin's simulation model, the timing
// reports and the netlist were all fine.
//
// Anything else (the branch predictor's 512 x 50, whose single mask bit is
// just a write enable): a plain array, inferred.
//
// rdLatency 1 only; readUnderWrite is "dontCare" in all current uses.

module Ram_1w_1rs #(
  parameter wordCount      = 512,
  parameter wordWidth      = 64,
  parameter clockCrossing  = 1'b0,
  parameter technology     = "auto",
  parameter readUnderWrite = "dontCare",
  parameter wrAddressWidth = 9,
  parameter wrDataWidth    = 64,
  parameter wrMaskWidth    = 1,
  parameter wrMaskEnable   = 1'b0,
  parameter rdAddressWidth = 9,
  parameter rdDataWidth    = 64,
  parameter rdLatency      = 1
) (
  input  wire                      wr_clk,
  input  wire                      wr_en,
  input  wire [wrMaskWidth-1:0]    wr_mask,
  input  wire [wrAddressWidth-1:0] wr_addr,
  input  wire [wrDataWidth-1:0]    wr_data,
  input  wire                      rd_clk,
  input  wire                      rd_en,
  input  wire [rdAddressWidth-1:0] rd_addr,
  input  wire                      rd_dataEn,
  output wire [rdDataWidth-1:0]    rd_data
);

  genvar k;
  generate
    if (wordCount <= 1024 && wordWidth == 64 && wrMaskWidth == 8 && wrMaskEnable &&
        wrDataWidth == 64 && rdDataWidth == 64) begin : sdpb

      // Word addresses padded to the blocks' 10 bits.
      wire [9:0] wa = wr_addr;
      wire [9:0] ra = rd_addr;
      wire [13:0] adb = {ra, 4'b0000};

      for (k = 0; k < 4; k = k + 1) begin : blk
        // SDPB, 16-bit mode: port A writes (CEA = write enable, ADA[13:4]
        // word address, ADA[1:0] byte enables), port B reads (ADB[13:4],
        // CEB = read enable; the output holds while CEB is low). Plain
        // wires on the ports: Gowin synthesis rejects expressions there.
        wire [1:0]  be  = wr_mask[2*k+1:2*k];
        wire [13:0] ada = {wa, 2'b00, be};
        wire        cea = wr_en & (|be);
        wire [31:0] di  = {16'd0, wr_data[16*k+15:16*k]};
        wire [31:0] q;
        assign rd_data[16*k+15:16*k] = q[15:0];

        SDPB ram (
          .DO(q), .DI(di), .BLKSELA(3'b000), .BLKSELB(3'b000),
          .ADA(ada), .ADB(adb),
          .CLKA(wr_clk), .CLKB(rd_clk),
          .CEA(cea), .CEB(rd_en),
          .OCE(1'b1), .RESETA(1'b0), .RESETB(1'b0)
        );
        defparam ram.READ_MODE = 1'b0;
        defparam ram.BIT_WIDTH_0 = 16;
        defparam ram.BIT_WIDTH_1 = 16;
        defparam ram.BLK_SEL_0 = 3'b000;
        defparam ram.BLK_SEL_1 = 3'b000;
        defparam ram.RESET_MODE = "SYNC";
      end

    end else begin : inferred

      // Only a single mask bit (a write enable) is supported here.
      reg [wordWidth-1:0] mem [0:wordCount-1];
      reg [rdDataWidth-1:0] q;
      wire we = wr_en && (!wrMaskEnable || wr_mask[0]);
      always @(posedge wr_clk)
        if (we) mem[wr_addr] <= wr_data;
      always @(posedge rd_clk)
        if (rd_en) q <= mem[rd_addr];
      assign rd_data = q;

    end
  endgenerate

endmodule
