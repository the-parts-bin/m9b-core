`timescale 1ns / 1ps
// USB host core (usb_hid_host.v, both ports) against two usb_ls_device
// models. With -DOLD: two copies of the single-port core as it was before
// the shared engine (OLD_SRC), to check the model against it.
//   K0, K1     device kinds on ports 0 and 1 (usb_ls_device: 0 none,
//              1 keyboard, 2 mouse, 3 dead)
//   SIM_MS     length
//   UNPLUG     unplug port 0's device at 500 ms, plug it back at 600 ms
//   RST        hold port 1 in reset from 700 to 705 ms
// Checks: device types, every report the host takes against what the device
// sent, reports keep coming, and the longest time without a keep-alive on
// each port (a device suspends after 3 ms).
module tb;
`ifndef K0
  `define K0 1
`endif
`ifndef K1
  `define K1 2
`endif
`ifndef SIM_MS
  `define SIM_MS 1200
`endif
  reg clk = 0; always #41.667 clk = ~clk;

  reg [3:0] rom [0:1023];
  initial begin : ld integer i; for (i = 0; i < 1024; i = i + 1) rom[i] = 0; $readmemh("../rtl/usb_hid_host_rom.hex", rom, 0, 535); end
  reg [13:0] fr = 0; wire sof = fr == 12001; always @(posedge clk) fr <= sof ? 0 : fr + 1;

  wire dm0, dp0, dm1, dp1;
  usb_ls_device #(.KIND(`K0), .SEED(11)) dev0 (.clk(clk), .dm(dm0), .dp(dp0));
  usb_ls_device #(.KIND(`K1), .SEED(22)) dev1 (.clk(clk), .dm(dm1), .dp(dp1));

  reg [1:0] rst_n = 0;
  wire [1:0] typ0, typ1, conerr;
  wire [1:0] rep;
  wire [47:0] rpt0, rpt1;
`ifdef OLD
  wire [9:0] a0, a1; reg [3:0] d0, d1;
  always @(posedge clk) begin d0 <= rom[a0]; d1 <= rom[a1]; end
  usb_hid_host_1p h0 (.usbclk(clk), .usbrst_n(rst_n[0]), .sof(sof), .usb_dm(dm0), .usb_dp(dp0), .typ(typ0), .report(rep[0]),
    .conerr(conerr[0]), .rpt(rpt0), .dbg_ukp(), .rom_adr(a0), .rom_data(d0));
  usb_hid_host_1p h1 (.usbclk(clk), .usbrst_n(rst_n[1]), .sof(sof), .usb_dm(dm1), .usb_dp(dp1), .typ(typ1), .report(rep[1]),
    .conerr(conerr[1]), .rpt(rpt1), .dbg_ukp(), .rom_adr(a1), .rom_data(d1));
`else
  wire [9:0] a; reg [3:0] d;
  always @(posedge clk) d <= rom[a];
  wire report, report_port; wire [47:0] rpt;
  usb_hid_host h (.usbclk(clk), .usbrst_n(rst_n), .sof(sof), .usb_dm0(dm0), .usb_dp0(dp0), .usb_dm1(dm1), .usb_dp1(dp1),
    .typ({typ1, typ0}), .report(report), .report_port(report_port), .conerr(conerr), .rpt(rpt), .dbg_ukp(), .rom_adr(a), .rom_data(d));
  assign rep = {report & report_port, report & ~report_port};
  assign rpt0 = rpt, rpt1 = rpt;
`endif

  // Host-side reports against what each device sent
  integer ok [0:1], bad [0:1], other [0:1];
  initial begin ok[0] = 0; ok[1] = 0; bad[0] = 0; bad[1] = 0; other[0] = 0; other[1] = 0; end
  task check(input integer p, input [47:0] r, input [63:0] sent, input was_report, input integer kind); reg [47:0] m; begin
    m = kind == 2 ? 48'h00_00_FF_FF_FF_FF : 48'hFF_FF_FF_FF_FF_FF;   // a mouse sends 4 bytes
    if (!was_report) other[p] = other[p] + 1;
    else if ((r & m) == (sent[47:0] & m)) ok[p] = ok[p] + 1;
    else begin
      bad[p] = bad[p] + 1;
      if (bad[p] < 5) $display("%0t ms: port %0d report %h, device sent %h", $realtime / 1e6, p, r, sent);
    end
  end endtask
  // (rpt is taken a cycle after the pulse, as usb_port does a few cycles later)
  always @(posedge clk) begin
    if (rep[0]) #1 check(0, rpt0, dev0.last_data, dev0.last_was_report, `K0);
    if (rep[1]) #1 check(1, rpt1, dev1.last_data, dev1.last_was_report, `K1);
  end

  // Reports at random, every 2-20 ms per device
  integer seed = 5;
  function [63:0] rand_report(input integer kind); reg [63:0] r; begin
    r = {$random(seed), $random(seed)};
    if (kind == 1) r[15:8] = 0;
    rand_report = r;
  end endfunction
  initial forever begin #(($unsigned($random(seed)) % 18000 + 2000) * 1000.0); if (dev0.configured) dev0.push_report(rand_report(`K0)); end
  initial forever begin #(($unsigned($random(seed)) % 18000 + 2000) * 1000.0); if (dev1.configured) dev1.push_report(rand_report(`K1)); end

  // Enumeration times
  real t_typ0 = -1, t_typ1 = -1;
  always @(posedge clk) begin
    if (typ0 != 0 && t_typ0 < 0) t_typ0 = $realtime / 1e6;
    if (typ1 != 0 && t_typ1 < 0) t_typ1 = $realtime / 1e6;
  end

  integer acked_mid [0:1];
  initial begin
    #1000 rst_n = 2'b11;
`ifdef UNPLUG
    #(500e6 - 1000);
    dev0.attached = 0; $display("%0t ms: port 0 unplugged", $realtime / 1e6);
    #100e6;
    dev0.attached = 1; $display("%0t ms: port 0 plugged in", $realtime / 1e6);
    t_typ0 = -1;
`endif
`ifdef RST
    #(700e6 - $realtime);
    rst_n[1] = 0; $display("%0t ms: port 1 reset", $realtime / 1e6);
    #5e6 rst_n[1] = 1;
    t_typ1 = -1;
`endif
  end

  initial begin
    #(`SIM_MS * 1e6);
    $display("port 0 (kind %0d): type %0d at %0.1f ms, reports ACKed %0d, host ok %0d bad %0d other %0d, NAKs %0d, bus resets %0d, longest keep-alive gap %0.3f ms",
      `K0, typ0, t_typ0, dev0.reports_acked, ok[0], bad[0], other[0], dev0.naks, dev0.bus_resets, dev0.max_gap / 1e6);
    $display("port 1 (kind %0d): type %0d at %0.1f ms, reports ACKed %0d, host ok %0d bad %0d other %0d, NAKs %0d, bus resets %0d, longest keep-alive gap %0.3f ms",
      `K1, typ1, t_typ1, dev1.reports_acked, ok[1], bad[1], other[1], dev1.naks, dev1.bus_resets, dev1.max_gap / 1e6);
    $finish;
  end
endmodule
