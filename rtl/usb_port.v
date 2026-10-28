// One USB host port's registers on the CPU clock, and its reset: the host
// core (usb_hid_host.v, 12 MHz domain) serves both ports, soc.v has one of
// these per port.
//
// Each report is announced with a toggle; the CPU domain copies the
// core's report outputs two flops later (they only change at the next
// report, at least 1 ms on), counts the report, adds a mouse's
// motion to MOUSE_POS and pulses report_event. Device type and error are
// levels through two flops.
//
// Registers (reg_sel = address bits 4:2):
//   0 STATUS    bits 1:0 device type (0 none, 1 keyboard, 2 mouse,
//               3 gamepad), bit 2 the core's watchdog, bits 15:8 report
//               count; write bit 0: hold the core in reset
//   1 KEYS      {key3, key2, key1, modifiers}   (report bytes 4, 3, 2, 0)
//   2 KEYS2     bits 7:0 key4                   (report byte 5)
//   3 MOUSE     {8'b0, dy, dx, buttons}         (report bytes 2, 1, 0)
//               These are the last report's raw bytes whatever the device
//               type: check STATUS's type first.
//   4 DEBUG     {connected, oe, dm, dp, 4'b0, pc[9:0]} (one flop: bits
//               may be read mid-change)
//   5 MOUSE_POS {y, x}: 16-bit running sums of the mouse's motion (they
//               wrap; read twice and subtract)

module usb_port (
  input  wire        cpu_clk,
  input  wire        rst_n,        // cpu_clk domain
  input  wire        usb_clk,      // 12 MHz

  input  wire [2:0]  reg_sel,
  input  wire        reg_write,    // this port selected and written
  input  wire [31:0] wdata,
  output wire [31:0] rdata,
  output wire        report_event, // one cpu_clk pulse per report

  // This port's side of the host core (usb_clk domain)
  output wire        usb_rst_n,
  input  wire [1:0]  typ,
  input  wire        conerr,
  input  wire        report,       // pulse: a report for this port
  input  wire [47:0] latch,        // its bytes 0-5 (shared by the ports)
  input  wire [13:0] dbg
);

  // STATUS write, bit 0: hold the core in reset (it restarts, and
  // re-enumerates, when cleared).
  reg         sw_rst;
  always @(posedge cpu_clk) begin
    if (~rst_n) sw_rst <= 1'b0;
    else if (reg_write & (reg_sel == 3'd0)) sw_rst <= wdata[0];
  end
  wire        rst_any_n = rst_n & ~sw_rst;
  reg  [1:0]  rst_s;
  always @(posedge usb_clk or negedge rst_any_n) begin
    if (~rst_any_n) rst_s <= 2'b00;
    else rst_s <= {rst_s[0], 1'b1};
  end
  assign      usb_rst_n = rst_s[1];

  reg  [13:0] dbg_s;            // debug only: bits may be read mid-change
  always @(posedge cpu_clk) dbg_s <= dbg;

  // The core's report bytes hold still until the next transaction, at
  // least the ACK's 11 us after the report (either port's), so the CPU side
  // copies them directly, a few cycles after the toggle.
  reg         toggle;
  always @(posedge usb_clk or negedge usb_rst_n) begin
    if (~usb_rst_n) toggle <= 1'b0;
    else if (report) toggle <= ~toggle;
  end

  reg  [2:0]  tog_s;
  reg  [2:0]  lvl_s1, lvl_s2;
  reg  [47:0] regs;
  reg  [7:0]  count;
  reg  [15:0] pos_x, pos_y;
  wire        new_report = tog_s[2] ^ tog_s[1];
  always @(posedge cpu_clk) begin
    tog_s  <= {tog_s[1:0], toggle};
    lvl_s1 <= {conerr, typ};
    lvl_s2 <= lvl_s1;
    if (~rst_n) begin
      count <= 8'd0;
      regs <= 48'd0;
      pos_x <= 16'd0;
      pos_y <= 16'd0;
    end else if (new_report) begin
      regs <= latch;
      count <= count + 8'd1;
      if (lvl_s2[1:0] == 2'd2) begin
        pos_x <= pos_x + {{8{latch[15]}}, latch[15:8]};    // dx
        pos_y <= pos_y + {{8{latch[23]}}, latch[23:16]};   // dy
      end
    end
  end
  assign report_event = rst_n & new_report;

  assign rdata = reg_sel == 3'd0 ? {16'd0, count, 5'd0, lvl_s2} :
                 reg_sel == 3'd1 ? {regs[39:16], regs[7:0]} :
                 reg_sel == 3'd2 ? {24'd0, regs[47:40]} :
                 reg_sel == 3'd3 ? {8'd0, regs[23:0]} :
                 reg_sel == 3'd4 ? {14'd0, dbg_s[13:10], 4'd0, dbg_s[9:0]} :
                 reg_sel == 3'd5 ? {pos_y, pos_x} :
                                   32'd0;
endmodule
