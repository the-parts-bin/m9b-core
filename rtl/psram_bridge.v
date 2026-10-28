// Maps the 8 MB of interleaved HyperRAM into the CPU's address space for
// the CPU's L1 caches. It only handles what the caches issue: whole 64-byte
// line bursts of 8 64-bit beats (CTI = incrementing, last beat CTI = 3'b111),
// reads for refills (fetch and data L1) and writes for write-backs (data
// L1, all byte lanes enabled).
//
// Each line goes through a line buffer in LUT RAM with one side in each
// clock domain, and one request to the PSRAM controller (hyperram.sv):
//   - refill: the first beat of a read burst sends a line request and the
//     bridge holds off ACK until the controller has filled rbuf, then
//     answers all 8 beats back to back from rbuf;
//   - write-back: all 8 beats are acked straight into wbuf and the line is
//     held there briefly: a refill that follows (the data L1 evicts just
//     before refilling) is sent first, and the write-back right after the
//     refill's ack. A refill of the same line, or none within a few cycles,
//     sends it first. A new write-back waits until wbuf is free.
//   - the controller acks a refill as its data starts arriving, and the
//     bridge answers the beats while the rest of the line comes in (the
//     controller writes a word per system_clk cycle, faster than the CPU
//     reads them).
// Requests cross clock domains as a toggle (line_req_toggle != synchronized
// line_ack_toggle = busy); line_write and line_addr are held stable from
// before the toggle until the ack.
module psram_bridge #(
  // 1: clk is system_clk / 2 (same clock tree, timed together): the ack
  // is used directly, without synchronizer flops.
  parameter SYNC = 0
) (
  input  wire        clk,         // CPU clock
  input  wire        rst_n,

  // Wishbone slave, 64-bit, CPU clock. adr is a 64-bit word address.
  input  wire        cyc,
  input  wire        stb,
  input  wire        we,
  input  wire [28:0] adr,
  input  wire [63:0] dat_w,
  input  wire [2:0]  cti,
  output wire        ack,
  output wire        rd_ack,   // the read beats among ack: from registers only
  output wire [63:0] dat_r,

  // PSRAM controller side (see hyperram.sv's line request ports).
  input  wire        system_clk,
  output reg         line_req_toggle,
  output reg         line_write,
  output reg  [17:0] line_addr,     // PSRAM byte address bits 23:6
  input  wire        line_ack_toggle,
  input  wire [2:0]  buf_idx,       // beat index during the line's burst
  input  wire        rbuf_we,       // refill data from the controller
  input  wire [63:0] rbuf_wdata,
  output reg  [63:0] wbuf_rdata     // write-back data to the controller,
                                    // registered like a BRAM read
);

  reg [63:0] rbuf [0:7];
  reg [63:0] wbuf [0:7];

  always @(posedge system_clk) begin
    if (rbuf_we) rbuf[buf_idx] <= rbuf_wdata;
    wbuf_rdata <= wbuf[buf_idx];
  end

  reg [1:0] ack_s;
  always @(posedge clk) begin
    if (~rst_n) ack_s <= 2'b00;
    else        ack_s <= {ack_s[0], line_ack_toggle};
  end
  // With SYNC the ack still goes through one flop: straight from the
  // controller it would launch at a 72 MHz edge and reach the CPU's bus
  // logic (deep: trap state, flusher) within half a CPU cycle.
  reg ack_q;
  always @(posedge clk) ack_q <= line_ack_toggle;
  wire pending = line_req_toggle != (SYNC ? ack_q : ack_s[1]);

  reg rd_wait;    // refill requested, waiting for the controller
  reg rd_valid;   // rbuf holds (or is receiving) the line, beats being answered
  reg wb_held;    // wbuf holds a write-back not yet sent to the controller
  reg [17:0] wb_addr;
  reg [2:0]  wb_timer;

  wire req      = cyc & stb;
  wire wr_beat  = req & we & ~pending & ~wb_held;
  // Beat 0 is answered in the cycle the refill's ack arrives (rd_wait with
  // pending clear), the rest while rd_valid. (In SYNC mode that is at the
  // earliest 41.7 ns after the controller's ack, and it writes word 0 into
  // rbuf 27.8 ns after it, then a word per 13.9 ns: timed as one design.)
  // Read beats don't look at cyc/stb (a long combinational path from the
  // CPU's refill logic through the bus mux to here and back): once a refill
  // is accepted (rd_wait, rd_valid), the L1 holds its read burst on the bus
  // until the last beat.
  wire rd_first = (SYNC != 0) & rd_wait & ~pending;
  wire rd_beat  = rd_valid | rd_first;
  assign rd_ack = rd_beat;
  assign ack    = wr_beat | rd_beat;
  assign dat_r  = rbuf[adr[2:0]];

  always @(posedge clk) begin
    if (wr_beat) wbuf[adr[2:0]] <= dat_w;
  end

  // A write-back is held in wbuf for a few cycles instead of being sent at
  // once: the data L1 evicts a dirty line just before refilling its slot,
  // and the refill (what the CPU waits for) goes to the controller first.
  // The write-back follows as soon as the controller acks the refill (when
  // its data starts arriving), overlapping the beats. It goes first when
  // the read is for the same line, and on its own when no read comes
  // within WB_HOLD cycles (so a cbo.clean still reaches PSRAM promptly).
  localparam [2:0] WB_HOLD = 3'd4;
  wire rd_new   = req & ~we & ~pending & ~rd_wait & ~rd_valid;
  // (While a refill is in flight the held write-back waits for its ack,
  // below: going out here as well would toggle the request twice.)
  // "Same line" compares only line-address bits 12:8 (byte address bits
  // 18:14, the low tag bits of both L1s): a full 18-bit compare sat on the
  // CPU's critical path. A false match only sends the write-back first (the
  // safe order); a real match always matches. The data L1's evict/refill
  // pairs share their index bits, so these bits rarely match falsely.
  wire wb_same  = adr[15:11] == wb_addr[12:8];
  wire wb_first = wb_held & ~rd_wait & (~rd_new | wb_same) & (rd_new | wb_timer == 3'd0);

  always @(posedge clk) begin
    if (~rst_n) begin
      line_req_toggle <= 1'b0;
      line_write <= 1'b0;
      line_addr <= 18'd0;
      rd_wait <= 1'b0;
      rd_valid <= 1'b0;
      wb_held <= 1'b0;
      wb_addr <= 18'd0;
      wb_timer <= 3'd0;
    end else begin
      if (wb_held && wb_timer != 3'd0) wb_timer <= wb_timer - 3'd1;
      if (wr_beat && cti == 3'b111) begin
        wb_held <= 1'b1;
        wb_addr <= adr[20:3];
        wb_timer <= WB_HOLD;
      end
      if (!pending && wb_first) begin
        // the held write-back goes out (a read waits for it)
        line_req_toggle <= ~line_req_toggle;
        line_write <= 1'b1;
        line_addr <= wb_addr;
        wb_held <= 1'b0;
      end else if (rd_new) begin
        line_req_toggle <= ~line_req_toggle;
        line_write <= 1'b0;
        line_addr <= adr[20:3];
        rd_wait <= 1'b1;
      end
      if (rd_wait && !pending) begin
        rd_wait <= 1'b0;
        rd_valid <= 1'b1;
        if (wb_held) begin
          // the refill is acked: now the held write-back
          line_req_toggle <= ~line_req_toggle;
          line_write <= 1'b1;
          line_addr <= wb_addr;
          wb_held <= 1'b0;
        end
      end
      if (rd_beat && cti == 3'b111)
        rd_valid <= 1'b0;
    end
  end

endmodule
