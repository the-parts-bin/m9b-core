// Behavioural model of the Tang Nano 9K's embedded HyperRAM (Winbond
// W955D8MBYA, datasheet A01-001), just enough to exercise rtl/hyperram.sv:
//   - 48-bit command/address on the first 6 CK edges (MSB byte first)
//   - register writes: 2 data bytes right after CA, zero latency
//   - register reads: CR0/CR1 (CA[0]), same latency as memory reads,
//     value repeated for the rest of the burst
//   - memory reads/writes: fixed 2x latency (RWDS driven high during CA),
//     first data byte on the rising edge of CK clock 2 + 2*LAT (clocks
//     counted from 0 at the first CA rising edge; datasheet Figure 9: the
//     latency count starts at the 4th CA edge)
//   - reads: DQ and RWDS driven edge-aligned, TCKD after each CK edge
//   - writes: DQ sampled on each CK edge, RWDS high masks the byte
//   - memory bursts wrap within the CR0[1:0] burst length (128/64/16/32
//     bytes), as the W955D8MBYA has no linear burst; CA[45] must be 0 for
//     memory (1 is flagged)
//   - checks: tIS/tIH = 0.9 ns on every CA/write-data capture, tCSS = 2 ns
// Not modelled: refresh collisions, variable latency, tCKD min/max spread
// (sweep TCKD instead), latency changes via CR0[7:4].
module psram_model #(
  parameter real    TCKD = 3.0,  // CK edge -> DQ/RWDS out on reads (ns)
  parameter integer LAT  = 6     // initial latency (clocks, doubled)
) (
  input        ck,
  input        ck_n,
  input        cs_n,
  input        reset_n,
  inout  [7:0] dq,
  inout        rwds
);

  reg  [7:0] dq_o    = 8'h00;
  reg        dq_oe   = 1'b0;
  reg        rwds_o  = 1'b0;
  reg        rwds_oe = 1'b0;
  assign dq   = dq_oe   ? dq_o   : 8'bz;
  assign rwds = rwds_oe ? rwds_o : 1'bz;

  reg [15:0] mem [0:65535];
  integer i;
  initial for (i = 0; i < 65536; i = i + 1) mem[i] = 16'hEE00 | i[7:0];

  reg [47:0] ca;
  integer    edge_n;        // CK edge index since CS# fell (0 = first rising)
  reg        is_read, is_reg, is_wrap;
  reg [21:0] haddr;         // half-word address
  integer    data_edge0;
  reg [15:0] cr0 = 16'h8f1f;
  reg [15:0] cr1 = 16'hffc1;
  reg [15:0] reg_word;
  always @(negedge reset_n) begin
    cr0 = 16'h8f1f;
    cr1 = 16'hffc1;
  end

  // Half-word address of burst half-word j: wraps within the CR0 burst
  // length group containing haddr.
  function [15:0] burst_addr(input integer j);
    reg [21:0] len;
    begin
      case (cr0[1:0])
        2'b00: len = 64;
        2'b01: len = 32;
        2'b10: len = 8;
        default: len = 16;
      endcase
      if (is_wrap)
        burst_addr = ((haddr & ~(len - 1)) | ((haddr + j) & (len - 1))) & 16'hffff;
      else
        burst_addr = (haddr + j) & 16'hffff;
    end
  endfunction

  localparam real TIS  = 0.9;   // input setup (DQ, RWDS mask) to CK edge
  localparam real TIH  = 0.9;   // input hold after CK edge
  localparam real TCSS = 2.0;   // CS# low to next CK rising edge

  // Setup/hold checks on host-driven captures. dq_changed is the last time
  // DQ (or RWDS, which masks writes) changed; last_capture the last CK
  // edge at which the model latched host data.
  realtime dq_changed   = 0;
  realtime last_capture = -100;
  realtime cs_fell      = 0;
  reg      capturing    = 1'b0;
  task input_changed;
    begin
      dq_changed = $realtime;
      if (capturing && $realtime - last_capture < TIH)
        $display("%t psram: WARNING hold %0.3f ns < %0.1f ns", $realtime,
                 $realtime - last_capture, TIH);
    end
  endtask
  always @(dq)   if (!dq_oe) input_changed;
  // RWDS only counts while the host drives it (write data mask).
  always @(rwds) if (!rwds_oe && rwds !== 1'bz) input_changed;
  task check_setup;
    begin
      if ($realtime - dq_changed < TIS)
        $display("%t psram: WARNING setup %0.3f ns < %0.1f ns (edge %0d)",
                 $realtime, $realtime - dq_changed, TIS, edge_n);
      last_capture = $realtime;
    end
  endtask

  always @(negedge cs_n) begin
    edge_n  = 0;
    ca      = 48'h0;
    cs_fell = $realtime;
    capturing = 1'b1;
    // Fixed latency: RWDS high during CA means "2x latency".
    rwds_o  <= #(TCKD) 1'b1;
    rwds_oe <= #(TCKD) 1'b1;
  end

  // Bytes stored by the current memory write burst, reported when CS#
  // goes high (host bursts should store whole lines / blocks).
  integer write_bytes = 0;

  always @(posedge cs_n) begin
    if (!is_read && !is_reg && write_bytes > 0)
      $display("%t psram: write burst stored %0d bytes", $realtime, write_bytes);
    write_bytes = 0;
    capturing = 1'b0;
    dq_oe   <= #(TCKD) 1'b0;
    rwds_oe <= #(TCKD) 1'b0;
  end

  always @(ck) if (!cs_n && reset_n && (ck === 1'b1 || ck === 1'b0)) begin
    if (edge_n == 0 && $realtime - cs_fell < TCSS)
      $display("%t psram: WARNING tCSS %0.3f ns < %0.1f ns", $realtime,
               $realtime - cs_fell, TCSS);
    if (edge_n < 6) begin
      check_setup;
      ca = {ca[39:0], dq};
      if (edge_n == 5) begin
        is_read    = ca[47];
        is_reg     = ca[46];
        is_wrap    = !ca[45];
        if (!is_reg && ca[45])
          $display("%t psram: WARNING CA[45]=1 on a memory access (undefined on W955D8MBYA; modelled as linear)",
                   $realtime);
        haddr      = {ca[34:16], ca[2:0]};
        data_edge0 = 2 * (2 + 2 * LAT);
        $display("%t psram: CA=%h %s %s haddr=%h", $realtime, ca,
                 is_read ? "READ" : "WRITE", is_reg ? "REG" : "MEM", haddr);
        if (!is_read) rwds_oe <= #(TCKD) 1'b0;   // host drives RWDS on writes
        else          rwds_o  <= #(TCKD) 1'b0;   // read preamble: RWDS low
        if (is_read) capturing = 1'b0;
      end
    end else if (is_reg && !is_read) begin
      if (edge_n <= 7) check_setup;
      if (edge_n == 6) reg_word[15:8] = dq;
      if (edge_n == 7) begin
        reg_word[7:0] = dq;
        if (ca[0]) cr1 = reg_word; else cr0 = reg_word;
        $display("%t psram: register write CR%0d = %h", $realtime, ca[0], reg_word);
      end
    end else if (edge_n >= data_edge0) begin
      // Byte j of the burst: even j = high byte of half-word j/2.
      if (is_read) begin
        reg_word = is_reg ? (ca[0] ? cr1 : cr0)
                          : mem[burst_addr((edge_n - data_edge0) / 2)];
        dq_o    <= #(TCKD) ((edge_n - data_edge0) % 2 == 0) ? reg_word[15:8] : reg_word[7:0];
        rwds_o  <= #(TCKD) ((edge_n - data_edge0) % 2 == 0);
        dq_oe   <= #(TCKD) 1'b1;
      end else begin
        check_setup;
        if (rwds === 1'b0) begin
          write_bytes = write_bytes + 1;
          if ((edge_n - data_edge0) % 2 == 0)
            mem[burst_addr((edge_n - data_edge0) / 2)][15:8] = dq;
          else
            mem[burst_addr((edge_n - data_edge0) / 2)][7:0] = dq;
        end
      end
    end
    edge_n = edge_n + 1;
  end

endmodule
