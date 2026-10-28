`timescale 1ns / 1ps
// Low-speed USB HID device model for tb_usb.v, on the host's 12 MHz clock
// (8 cycles a bit). KIND: 0 nothing attached, 1 keyboard, 2 mouse, 3 a dead
// device (D- pulled up but never answering, like a combo keyboard stuck in
// PS/2 mode). The testbench sets `attached` and queues reports with
// push_report.
//   - Decodes the host's packets (NRZI, bit stuffing), answers SETUP + DATA0
//     with ACK, IN on endpoint 0 with the requested descriptor in 8-byte
//     packets (then zero-length packets), IN on endpoint 1 with the next
//     queued report or NAK; NAKs ep0 INs at random (NAK_PCT).
//   - SET_ADDRESS takes effect after its status stage; a bus reset (SE0 for
//     over 2.5 us) clears the address.
//   - Counts reports ACKed by the host, and the longest time without a
//     keep-alive or packet once configured (a real device suspends after
//     3 ms).
module usb_ls_device #(
  parameter KIND = 1,
  parameter NAK_PCT = 20,
  parameter SEED = 1
) (
  input  wire clk,
  inout  wire dm,
  inout  wire dp
);
  reg attached = 1;
  reg tx = 0, tx_dm = 1, tx_dp = 0;
  assign dm = tx ? tx_dm : 1'bz;
  assign dp = tx ? tx_dp : 1'bz;
  // 1.5k pull-up on D- (low speed) when attached, the host's 15k pull-downs
  assign (weak0, weak1) dm = (attached && KIND != 0) ? 1'b1 : 1'b0;
  assign (weak0, weak1) dp = 1'b0;

  wire se0 = dm === 1'b0 && dp === 1'b0;
  wire j   = dm === 1'b1 && dp === 1'b0;
  wire k   = dm === 1'b0 && dp === 1'b1;

  integer rnd = SEED;
  function integer urand(input integer n); begin rnd = rnd * 1103515245 + 12345; urand = ((rnd >>> 16) & 32'h7fff) % n; end endfunction

  // Descriptors
  reg [7:0] dev_desc [0:17];
  reg [7:0] cfg_desc [0:33];
  integer i;
  initial begin
    for (i = 0; i < 18; i = i + 1) dev_desc[i] = 0;
    dev_desc[0] = 18; dev_desc[1] = 1; dev_desc[7] = 8;
    {cfg_desc[0], cfg_desc[1], cfg_desc[2], cfg_desc[3], cfg_desc[4], cfg_desc[5], cfg_desc[6], cfg_desc[7], cfg_desc[8]} =
      {8'd9, 8'd2, 8'd34, 8'd0, 8'd1, 8'd1, 8'd0, 8'hA0, 8'd50};
    {cfg_desc[9], cfg_desc[10], cfg_desc[11], cfg_desc[12], cfg_desc[13], cfg_desc[14], cfg_desc[15], cfg_desc[16], cfg_desc[17]} =
      {8'd9, 8'd4, 8'd0, 8'd0, 8'd1, 8'd3, 8'd1, (KIND == 2 ? 8'd2 : 8'd1), 8'd0};
    {cfg_desc[18], cfg_desc[19], cfg_desc[20], cfg_desc[21], cfg_desc[22], cfg_desc[23], cfg_desc[24], cfg_desc[25], cfg_desc[26]} =
      {8'd9, 8'h21, 8'h11, 8'h01, 8'd0, 8'd1, 8'h22, 8'd63, 8'd0};
    {cfg_desc[27], cfg_desc[28], cfg_desc[29], cfg_desc[30], cfg_desc[31], cfg_desc[32], cfg_desc[33]} =
      {8'd7, 8'd5, 8'h81, 8'h03, 8'd8, 8'd0, 8'd10};
  end

  // Report queue
  reg [63:0] rq [0:255];
  integer rq_h = 0, rq_t = 0;
  task push_report(input [63:0] r); begin rq[rq_t] = r; rq_t = (rq_t + 1) % 256; end endtask
  wire [7:0] rlen = KIND == 2 ? 8'd4 : 8'd8;

  // State
  reg [6:0]  addr = 0, new_addr = 0;
  reg        addr_pending = 0, configured = 0;
  reg [7:0]  ctl [0:63];
  integer    ctl_len = 0, ctl_pos = 0;
  reg        ctl_active = 0, setup_seen = 0, toggle = 1;
  reg        sent_report = 0, sent_status = 0;
  integer    reports_acked = 0, reports_sent = 0, naks = 0, bus_resets = 0;
  // What the host last received from us, for the testbench's check
  reg [63:0] last_data = 0;
  reg        last_was_report = 0;

  // Bus reset and keep-alive tracking
  integer se0_len = 0;
  real    t_act = 0, max_gap = 0;
  always @(posedge clk) begin
    if (se0) se0_len = se0_len + 1; else se0_len = 0;
    if (se0_len == 30 && attached && KIND != 0) begin
      addr = 0; addr_pending = 0; configured = 0; ctl_active = 0; bus_resets = bus_resets + 1;
    end
    if (!attached || KIND == 0 || !configured) t_act = $realtime;
    else if (se0) begin
      if ($realtime - t_act > max_gap) max_gap = $realtime - t_act;
      t_act = $realtime;
    end
  end

  // Packets
  reg [7:0] pkt [0:15];
  integer   nbytes;
  task receive; integer nb, ones; reg prev, b, line; begin
    // At the first K after idle; sample mid-bit
    repeat (4) @(posedge clk);
    prev = 1; nb = 0; ones = 0; nbytes = 0;
    for (i = 0; i < 16; i = i + 1) pkt[i] = 0;
    while (!se0) begin
      line = dm;
      b = (line == prev);
      prev = line;
      if (ones == 6) ones = 0;               // stuffed bit
      else begin
        if (nb < 128) pkt[nb / 8][nb % 8] = b;
        nb = nb + 1;
        ones = b ? ones + 1 : 0;
      end
      repeat (8) @(posedge clk);
    end
    nbytes = nb / 8;
    while (!j) @(posedge clk);               // end of packet
  end endtask

  task send_bit(input b, inout integer ones); begin
    if (!b) begin tx_dm = ~tx_dm; tx_dp = ~tx_dm; ones = 0; end else ones = ones + 1;
    repeat (8) @(posedge clk);
    if (ones == 6) begin tx_dm = ~tx_dm; tx_dp = ~tx_dm; ones = 0; repeat (8) @(posedge clk); end
  end endtask
  task send(input [7:0] pid, input integer n, input [63:0] d); integer ones, bi, bj; reg [15:0] crc; reg [7:0] by; begin
    repeat (32) @(posedge clk);              // turnaround (the host has let go of the bus)
    tx = 1; tx_dm = 1; tx_dp = 0; ones = 0;
    for (bi = 0; bi < 8; bi = bi + 1) send_bit(bi == 7, ones);
    for (bi = 0; bi < 8; bi = bi + 1) send_bit(pid[bi], ones);
    if (pid == 8'hC3 || pid == 8'h4B) begin  // DATA0/1: data and CRC16
      crc = 16'hFFFF;
      for (bj = 0; bj < n; bj = bj + 1) begin
        by = d[8*bj +: 8];
        for (bi = 0; bi < 8; bi = bi + 1) begin
          send_bit(by[bi], ones);
          crc = (crc[0] ^ by[bi]) ? (crc >> 1) ^ 16'hA001 : crc >> 1;
        end
      end
      crc = ~crc;
      for (bi = 0; bi < 16; bi = bi + 1) send_bit(crc[bi], ones);
    end
    tx_dm = 0; tx_dp = 0; repeat (16) @(posedge clk);
    tx_dm = 1; tx_dp = 0; repeat (8) @(posedge clk);
    tx = 0;
  end endtask

  reg [7:0] pid;
  reg [6:0] tok_addr;
  reg [3:0] tok_ep;
  reg [63:0] d;
  integer n, wlen;
  reg       last_tok_in = 0, last_in_ep1 = 0;
  initial begin
    while (1) begin : body
      @(posedge clk);
      if (KIND == 0 || KIND == 3 || !attached || !k || tx) disable body;
      receive;
      if (nbytes < 2) disable body;
      pid = pkt[1];
      if (pid == 8'hD2) begin                // ACK from the host
        if (last_tok_in) begin
          if (last_in_ep1 && sent_report) begin reports_acked = reports_acked + 1; rq_h = (rq_h + 1) % 256; end
          if (!last_in_ep1 && sent_status) begin
            if (addr_pending) begin addr = new_addr; addr_pending = 0; end
            else if (ctl[0] == 0 && ctl[1] == 9) configured = 1;
            ctl_active = 0;
          end
        end
        last_tok_in = 0;
        disable body;
      end
      if (pid == 8'h2D || pid == 8'h69) begin   // SETUP, IN
        tok_addr = pkt[2][6:0];
        tok_ep = {pkt[3][2:0], pkt[2][7]};
        last_tok_in = 0;
        if (tok_addr != addr) disable body;
        if (pid == 8'h2D) begin setup_seen = 1; disable body; end
        // IN
        sent_report = 0; sent_status = 0;
        last_tok_in = 1; last_in_ep1 = tok_ep == 1;
        if (tok_ep == 1) begin
          if (configured && rq_h != rq_t) begin
            d = rq[rq_h];
            last_data = d; last_was_report = 1;
            sent_report = 1; reports_sent = reports_sent + 1;
            send(toggle ? 8'h4B : 8'hC3, rlen, d); toggle = ~toggle;
          end else begin naks = naks + 1; send(8'h5A, 0, 0); end
        end else if (tok_ep == 0 && ctl_active && urand(100) >= NAK_PCT) begin
          n = ctl_len - ctl_pos; if (n > 8) n = 8; if (n < 0) n = 0;
          d = 0;
          for (i = 0; i < n; i = i + 1) d[8*i +: 8] = ctl[ctl_pos + i];
          ctl_pos = ctl_pos + n;
          last_data = d; last_was_report = 0;
          sent_status = n == 0;
          send(toggle ? 8'h4B : 8'hC3, n, d); toggle = ~toggle;
        end else begin naks = naks + 1; send(8'h5A, 0, 0); end
        disable body;
      end
      if ((pid == 8'hC3 || pid == 8'h4B) && setup_seen) begin   // the SETUP's data
        setup_seen = 0;
        for (i = 0; i < 8; i = i + 1) ctl[i] = pkt[2 + i];
        wlen = {pkt[9], pkt[8]};
        ctl_active = 1; ctl_pos = 0; toggle = 1;
        if (pkt[3] == 6) begin               // GET_DESCRIPTOR
          if (pkt[5] == 1) begin ctl_len = wlen < 18 ? wlen : 18; for (i = 0; i < 18; i = i + 1) ctl[8 + i] = dev_desc[i]; end
          else begin ctl_len = wlen < 34 ? wlen : 34; for (i = 0; i < 34; i = i + 1) ctl[8 + i] = cfg_desc[i]; end
          ctl_pos = 8;                       // data after the request
          ctl_len = ctl_len + 8;
        end else begin                       // no data stage: zero-length status
          if (pkt[3] == 5) begin new_addr = pkt[4][6:0]; addr_pending = 1; end
          ctl_pos = 8; ctl_len = 8;
        end
        send(8'hD2, 0, 0);                   // ACK
        last_tok_in = 0;
      end
    end
  end
endmodule
