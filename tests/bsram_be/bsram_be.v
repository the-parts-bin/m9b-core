// BSRAM byte-enable test for the Tang Nano 9K (GW1NR-9): all N block RAMs
// as DPB primitives, 1024 x 16 on both ports, byte enables on AD[1:0]
// (UG285: in x16 mode AD[13:4] is the address, AD[1] / AD[0] write the high
// / low byte). Each block is tested on its own (its CEs).
//
// Directed, twice per block (writing through port A, then port B), every
// check reading each word through both ports:
//   1. fill: all words, both bytes (BE 11)
//   2. BE 01 (low byte only), with a different high byte in the data
//   3. BE 10 (high byte only), with a different low byte in the data: the
//      case that failed in the data L1 (lane 0 written anyway)
//   4. BE 00 with the write enable on: nothing may change
// Transitions, per block and writing port X (Y the other port): for every
// pair of byte enables p -> q (16), write p to a word through X, then q to
// the same word: kind 0 through X in the next cycle; kind 1 through Y in
// the next cycle; kind 2 through X after Y writes another word in between
// (ports alternating); kind 3 through X after an idle cycle. Initialize,
// write, read back through X, compare with the byte merge, low and high
// byte separately. 64 addresses each. Counted over the pass (all blocks,
// both X) and printed after its summary: one line per kind and byte lane,
// by "from p: to q".
// Stress, per block: 16 words (at a different place in each pass),
// initialized through port A and mirrored in registers; then STRESS cycles in which each port, on its own, idles,
// reads, or writes a random one of them with random byte enables (00..11)
// and data, as a cache would (back-to-back writes and reads, the other port
// busy, enables changing every cycle; two ports on the same address in the
// same cycle are left out, undefined for the RAM). Every read is checked
// against the registers: bytes wrong, low and high, per port.
//
// After a block with a stress error, its first one is traced: the failing
// read (port, word, expected, got) and the 16 cycles of operations up to
// it, newest first (h4 is the failing read).
//
// One UART line per block (115200 8N1, on both TX pins) with an error count
// per case (words wrong on either port; stress: bytes wrong), then "pass N
// errors E"; repeats forever. LED 0 toggles per pass, LED 1 lights after
// any error.
//
// Clock: clk_sel.vh (written by build.sh) defines CLK_MHZ: 27 (the
// oscillator), 36 or 72 (rPLL as in ../../rtl/gowin_rpll/pll_main.v:
// 144 MHz / 4 or / 2). For 72 MHz everything is pipelined: the stress
// operations are decoded into registers, all RAM inputs come from
// registers (as a cache bank's would), the selected block's read data is
// registered, and the report printer fetches each character a cycle ahead.
// A read issued by the state machine in cycle t has its data in doa_s /
// dob_s in cycle t + 5 (input registers, the RAM, its output registers,
// two stages of choosing the block).
//
// Results on the board (2026-10-16, all 26 blocks, 27/36/72 MHz): the
// directed tests pass, but byte enables misbehave on back-to-back writes:
// when a port writes in two consecutive cycles, a byte lane enabled in the
// first write and disabled in the second is written anyway in 10-36% of
// cases (by p -> q: 01->00 27%, 01->10 36%, 11->10 22%, 11->00 10% low /
// 3% high; 10->00 15%, 10->01 24%, 11->01 11%, all of the disabled lane
// only). An idle cycle or a read on that port between the writes avoids
// it completely (0 errors), and so does a write on the other port: the
// second write through the other port (same word, next cycle) and ports
// alternating are both clean. It is per port. Full-word writes never
// fail. Gowin's simulation model doesn't do any of this.
//
// Gowin synthesis: no forward references, no expressions on primitive
// ports.
`include "clk_sel.vh"   // `define CLK_MHZ
module bsram_be #(
  parameter N        = 26,
  parameter UART_DIV = (`CLK_MHZ * 1000000 + 57600) / 115200,
  parameter STRESS   = 65536   // random cycles per block
) (
  input  wire       ext_clk,   // 27 MHz
  input  wire       reset,     // button, active low
  output wire       txd,       // BL702
  output wire       txd2,      // header J5 (external USB-serial adapter)
  output wire [5:0] led        // active low
);
  wire clk;
  generate
    if (`CLK_MHZ == 27) begin : osc
      assign clk = ext_clk;
    end else begin : pll
      wire clkout, clkoutd, lock;
      wire gnd = 1'b0;
      wire [5:0] gnd6 = 6'd0;
      wire [3:0] gnd4 = 4'd0;
      rPLL #(
        .FCLKIN("27"), .DYN_IDIV_SEL("false"), .IDIV_SEL(2),
        .DYN_FBDIV_SEL("false"), .FBDIV_SEL(15), .DYN_ODIV_SEL("false"), .ODIV_SEL(4),
        .PSDA_SEL("0000"), .DYN_DA_EN("true"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1), .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"), .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"),
        .CLKOUTD_BYPASS("false"), .DYN_SDIV_SEL(`CLK_MHZ == 72 ? 2 : 4),
        .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"), .DEVICE("GW1NR-9C")
      ) rpll (
        .CLKOUT(clkout), .LOCK(lock), .CLKOUTP(), .CLKOUTD(clkoutd), .CLKOUTD3(),
        .RESET(gnd), .RESET_P(gnd), .CLKIN(ext_clk), .CLKFB(gnd),
        .FBDSEL(gnd6), .IDSEL(gnd6), .ODSEL(gnd6), .PSDA(gnd4), .DUTYDA(gnd4), .FDLY(gnd4)
      );
      assign clk = clkoutd;
    end
  endgenerate

  // Power-on / button reset.
  reg [7:0] por = 8'd0;
  always @(posedge clk) por <= !reset ? 8'd0 : (por == 8'hFF ? por : por + 8'd1);
  wire rst = por != 8'hFF;

  // ------------------------------------------------------------------
  // UART transmitter
  // ------------------------------------------------------------------
  reg  [9:0]  tx_sh = 10'h3FF;
  reg  [3:0]  tx_bits = 4'd0;
  reg  [15:0] tx_cnt = 16'd0;
  wire        tx_busy = tx_bits != 4'd0;
  reg         tx_go;
  reg  [7:0]  tx_char;
  always @(posedge clk) begin
    if (rst) begin
      tx_sh <= 10'h3FF;
      tx_bits <= 4'd0;
    end else if (!tx_busy) begin
      if (tx_go) begin
        tx_sh <= {1'b1, tx_char, 1'b0};
        tx_bits <= 4'd10;
        tx_cnt <= UART_DIV - 1;
      end
    end else if (tx_cnt != 16'd0) begin
      tx_cnt <= tx_cnt - 16'd1;
    end else begin
      tx_sh <= {1'b1, tx_sh[9:1]};
      tx_bits <= tx_bits - 4'd1;
      tx_cnt <= UART_DIV - 1;
    end
  end
  assign txd  = tx_sh[0];
  assign txd2 = tx_sh[0];

  // ------------------------------------------------------------------
  // Test state
  // ------------------------------------------------------------------
  localparam S_HELLO = 4'd0, S_W = 4'd1, S_RD = 4'd2, S_WAIT = 4'd3, S_CMP = 4'd4,
             S_NEXT = 4'd5, S_PRINT = 4'd6, S_SUM = 4'd7, S_SINIT = 4'd8,
             S_STRESS = 4'd9, S_DRAIN = 4'd10, S_TRACE = 4'd11, S_PAIR = 4'd12;
  reg  [3:0]  state;
  reg  [1:0]  wait_n;   // S_WAIT cycles left
  reg  [4:0]  blk;      // block under test
  reg         wp;       // writing port: 0 A, 1 B
  reg  [2:0]  ph;       // 0 fill, 1 check, 2 BE 01, 3 check, 4 BE 10, 5 check, 6 BE 00, 7 check
  reg  [9:0]  addr;
  reg  [15:0] pass;
  reg  [31:0] total;
  reg         any_err;
  reg  [16:0] scnt;     // stress cycles left / init words / drain cycles

  // Directed patterns (bytes) for address addr, block blk, writing port wp.
  wire [7:0] p1l = addr[7:0] ^ {addr[9:8], blk, wp};
  wire [7:0] p1h = ~addr[7:0] ^ {wp, blk, addr[9:8]};
  wire [7:0] px  = addr[7:0] ^ 8'h3C ^ {addr[9:8], 6'd0};
  wire [7:0] py  = addr[7:0] ^ 8'hC3 ^ {6'd0, addr[9:8]};

  // What the write phases write, and the byte enables.
  reg  [15:0] wdata;
  reg  [1:0]  be;
  always @(*) begin
    case (ph)
      3'd0:    begin wdata = {p1h, p1l};   be = 2'b11; end
      3'd2:    begin wdata = {~p1h, px};   be = 2'b01; end   // high byte must stay p1h
      3'd4:    begin wdata = {py, ~px};    be = 2'b10; end   // low byte must stay px
      default: begin wdata = {~py, ~px};   be = 2'b00; end   // nothing may change
    endcase
  end
  // What the check after each write phase expects.
  reg  [15:0] exp_w;
  always @(*) begin
    case (ph)
      3'd1:    exp_w = {p1h, p1l};
      3'd3:    exp_w = {p1h, px};
      default: exp_w = {py, px};
    endcase
  end

  // Stress: a 64-bit xorshift supplies each cycle's random operations,
  // which are decoded into registers (o_*) first: op 0 idle, 1 read, 2-3
  // write; port B idles when it would use port A's address in the same
  // cycle with either of them writing.
  reg  [63:0] rnd;
  wire [63:0] rnd1 = rnd ^ (rnd << 13);
  wire [63:0] rnd2 = rnd1 ^ (rnd1 >> 7);
  wire [63:0] rnd_next = rnd2 ^ (rnd2 << 17);
  wire [1:0]  opa  = rnd[1:0];
  wire [1:0]  opb0 = rnd[27:26];
  wire        conflict = opa != 2'd0 && opb0 != 2'd0 && rnd[5:2] == rnd[31:28] && (opa[1] | opb0[1]);
  wire [5:0]  sbase = pass[5:0] ^ {1'b0, blk};   // the 16 words: sbase * 16 ..
  wire        stressing = state == S_STRESS;
  reg         o_rd_a, o_wr_a, o_rd_b, o_wr_b;
  reg  [3:0]  o_sa_a, o_sa_b;   // word among the 16 (at sbase)
  reg  [1:0]  o_be_a, o_be_b;
  reg  [15:0] o_d_a, o_d_b;
  always @(posedge clk) begin
    o_rd_a <= stressing & (opa == 2'd1);
    o_wr_a <= stressing & opa[1];
    o_rd_b <= stressing & !conflict & (opb0 == 2'd1);
    o_wr_b <= stressing & !conflict & opb0[1];
    o_sa_a <= rnd[5:2];
    o_be_a <= rnd[9:8];
    o_d_a  <= rnd[25:10];
    o_sa_b <= rnd[31:28];
    o_be_b <= rnd[35:34];
    o_d_b  <= rnd[51:36];
  end
  reg  [15:0] shadow [0:15];     // what the 16 stress words should hold
  wire        sinit = state == S_SINIT;

  // Transition test: case pidx = {kind, p, q}, address index tpi, step
  // pst (one per cycle): 0 write x full (X), 3 write x with p (X), then
  //   kind 0: 4 write x with q (X)
  //   kind 1: 4 write x with q (Y)
  //   kind 2: 4 write y full (Y), 5 write x with q (X)
  //   kind 3: 4 idle, 5 write x with q (X)
  // 8 read x (X), compared in 13 (the data comes 5 cycles after the read).
  function [15:0] bmerge(input [15:0] o, input [15:0] n, input [1:0] e);
    bmerge = {e[1] ? n[15:8] : o[15:8], e[0] ? n[7:0] : o[7:0]};
  endfunction
  reg  [5:0]  pidx;
  reg  [5:0]  tpi;
  reg  [3:0]  pst;
  wire        pairing = state == S_PAIR;
  wire [1:0]  pkind = pidx[5:4];
  wire [1:0]  pp = pidx[3:2];
  wire [1:0]  pq = pidx[1:0];
  wire [7:0]  pi8 = {2'b00, tpi};
  wire [15:0] k1x = {8'hA5 ^ pi8, 8'h5A ^ pi8};
  wire [15:0] k1y = {8'h0F ^ pi8, 8'hF0 ^ pi8};
  wire [15:0] d1  = {8'h3C ^ pi8, 8'hC3 ^ pi8};
  wire [15:0] d2  = {8'h69 ^ pi8, 8'h96 ^ pi8};
  wire [15:0] xexp = bmerge(bmerge(k1x, d1, pp), d2, pq);
  wire [9:0]  px_ad = {4'b0000, tpi};
  wire [9:0]  py_ad = {4'b0001, tpi};
  wire        p_s4 = pst == 4'd4;
  wire        p_s5 = pst == 4'd5;
  wire        p_ymid = p_s4 & pkind == 2'd2;           // Y writes y full
  wire        p_other = p_s4 & (pkind == 2'd1 | pkind == 2'd2);   // this step on Y
  wire        p_we = pairing & ((pst == 4'd0) | (pst == 4'd3) | (p_s4 & pkind != 2'd3) |
                                (p_s5 & pkind[1]));
  wire        p_re = pairing & (pst == 4'd8);
  wire [9:0]  p_ad = p_ymid ? py_ad : px_ad;
  wire [1:0]  p_be = (pst == 4'd0 | p_ymid) ? 2'b11 : pst == 4'd3 ? pp : pq;
  wire [15:0] p_di = pst == 4'd0 ? k1x : p_ymid ? k1y : pst == 4'd3 ? d1 : d2;
  wire        p_onb = p_other ? !wp : wp;   // this step's port is B
  wire        pa = pairing & !p_onb;
  wire        pb = pairing & p_onb;

  // RAM inputs for the next cycle: directed (the write phases write through
  // port wp; the checks read the same address through both ports), the
  // stress init (port A), or the stress operations. Registered (r_*).
  wire        writing = state == S_W;
  wire        reading = state == S_RD;
  wire        n_ce_a  = (writing & !wp) | reading | sinit | o_rd_a | o_wr_a | (pa & (p_we | p_re));
  wire        n_ce_b  = (writing & wp) | reading | o_rd_b | o_wr_b | (pb & (p_we | p_re));
  wire        n_wre_a = (writing & !wp) | sinit | o_wr_a | (pa & p_we);
  wire        n_wre_b = (writing & wp) | o_wr_b | (pb & p_we);
  wire [1:0]  n_be_a  = (writing & !wp) ? be : sinit ? 2'b11 : o_wr_a ? o_be_a : (pa & p_we) ? p_be : 2'b00;
  wire [1:0]  n_be_b  = (writing & wp) ? be : o_wr_b ? o_be_b : (pb & p_we) ? p_be : 2'b00;
  wire [9:0]  n_ad_a  = sinit ? {sbase, scnt[3:0]} : (o_rd_a | o_wr_a) ? {sbase, o_sa_a} : pa ? p_ad : addr;
  wire [9:0]  n_ad_b  = (o_rd_b | o_wr_b) ? {sbase, o_sa_b} : pb ? p_ad : addr;
  wire [15:0] n_di_a  = sinit ? rnd[15:0] : o_wr_a ? o_d_a : pa ? p_di : wdata;
  wire [15:0] n_di_b  = o_wr_b ? o_d_b : pb ? p_di : wdata;
  reg         r_ce_a, r_ce_b, r_wre_a, r_wre_b;
  reg  [13:0] r_ada, r_adb;
  reg  [15:0] r_dia, r_dib;
  reg  [N-1:0] r_sel;           // one-hot: block blk
  reg  [N-1:0] r_sel1, r_sel2;   // ... as it was 1 and 2 cycles ago (outputs)
  integer j;
  always @(posedge clk) begin
    r_ce_a  <= n_ce_a;
    r_ce_b  <= n_ce_b;
    r_wre_a <= n_wre_a;
    r_wre_b <= n_wre_b;
    r_ada   <= {n_ad_a, 2'b00, n_be_a};
    r_adb   <= {n_ad_b, 2'b00, n_be_b};
    r_dia   <= n_di_a;
    r_dib   <= n_di_b;
    for (j = 0; j < N; j = j + 1) r_sel[j] <= blk == j;
    r_sel1 <= r_sel;
    r_sel2 <= r_sel1;
  end

  wire [2:0]  blksel  = 3'b000;
  wire        one     = 1'b1;
  wire        zero    = 1'b0;
  wire [16*N-1:0] doa_all, dob_all;

  genvar i;
  generate
    for (i = 0; i < N; i = i + 1) begin : b
      wire        cea = r_ce_a & r_sel[i];
      wire        ceb = r_ce_b & r_sel[i];
      wire [15:0] doa, dob;
`ifdef BE_FAULT
      // (simulation only) block 7's port A ignores its byte enables, as
      // the data L1's lane 0 did: the checker has to count it
      wire [13:0] ada_i = (i == 7) ? {r_ada[13:2], {2{r_ada[1] | r_ada[0]}}} : r_ada;
`else
      wire [13:0] ada_i = r_ada;
`endif
      DPB #(
        .READ_MODE0(1'b0), .READ_MODE1(1'b0),          // bypass: data the cycle after
        .WRITE_MODE0(2'b00), .WRITE_MODE1(2'b00),       // normal
        .BIT_WIDTH_0(16), .BIT_WIDTH_1(16),
        .BLK_SEL_0(3'b000), .BLK_SEL_1(3'b000),
        .RESET_MODE("SYNC")
      ) ram (
        .DOA(doa), .DOB(dob), .DIA(r_dia), .DIB(r_dib),
        .BLKSELA(blksel), .BLKSELB(blksel),
        .ADA(ada_i), .ADB(r_adb),
        .WREA(r_wre_a), .WREB(r_wre_b),
        .CLKA(clk), .CLKB(clk), .CEA(cea), .CEB(ceb),
        .OCEA(one), .OCEB(one), .RESETA(zero), .RESETB(zero)
      );
      // each block's outputs registered first (the 26-way choice below
      // doesn't fit in a 72 MHz cycle after the RAM's clock-to-output)
      // (zero unless this is the block under test, so they can be ORed)
      reg [15:0] doa_r, dob_r;
      always @(posedge clk) begin
        doa_r <= doa & {16{r_sel2[i]}};
        dob_r <= dob & {16{r_sel2[i]}};
      end
      assign doa_all[16*i +: 16] = doa_r;
      assign dob_all[16*i +: 16] = dob_r;
    end
  endgenerate

  // The block's read data: the gated outputs ORed, in groups of 4 into
  // registers, then the groups into doa_s / dob_s (3 registers after the
  // RAM).
  localparam G = (N + 3) / 4;
  reg  [15:0] ga [0:G-1], gb [0:G-1];
  reg  [15:0] doa_s, dob_s;
  integer g, m;
  reg  [15:0] acc_a, acc_b;
  always @(posedge clk) begin
    for (g = 0; g < G; g = g + 1) begin
      acc_a = 16'd0;
      acc_b = 16'd0;
      for (m = 0; m < 4; m = m + 1)
        if (4 * g + m < N) begin
          acc_a = acc_a | doa_all[16 * (4 * g + m) +: 16];
          acc_b = acc_b | dob_all[16 * (4 * g + m) +: 16];
        end
      ga[g] <= acc_a;
      gb[g] <= acc_b;
    end
    acc_a = 16'd0;
    acc_b = 16'd0;
    for (g = 0; g < G; g = g + 1) begin
      acc_a = acc_a | ga[g];
      acc_b = acc_b | gb[g];
    end
    doa_s <= acc_a;
    dob_s <= acc_b;
  end
  wire        bad_lo = (doa_s[7:0] != exp_w[7:0]) | (dob_s[7:0] != exp_w[7:0]);
  wire        bad_hi = (doa_s[15:8] != exp_w[15:8]) | (dob_s[15:8] != exp_w[15:8]);

  // Directed error counts for the block, per writing port: full, lo01,
  // hi01, lo10, hi10, be00 (16 bits each: at most 1024 per block).
  reg [15:0] c_full [0:1], c_lo01 [0:1], c_hi01 [0:1], c_lo10 [0:1], c_hi10 [0:1], c_00 [0:1];
  // transition test errors over the pass, by case and byte (counted a
  // cycle later; cleared one entry per cycle after the pass's report)
  reg [11:0] prc_lo [0:63], prc_hi [0:63];
  reg        pb_lo, pb_hi;
  reg [5:0]  pb_idx;
  reg        clr_p;
  reg [6:0]  pclr;   // < 64: clearing entry pclr
  // a check's result, counted a cycle later (timing)
  reg        ev_v, ev_lo, ev_hi, ev_wp;
  reg [2:0]  ev_ph;

  // Stress checks: a read decoded into o_* in cycle s is done by the RAM
  // in s + 1 and its data is in doa_s / dob_s in s + 5; chk / exp follow it.
  reg [15:0] s_lo_a, s_hi_a, s_lo_b, s_hi_b;   // bytes wrong (< 64K reads)
  reg        clr_s;                            // clears them (after a report)
  reg        chk_a1, chk_a2, chk_a3, chk_a4, chk_a5, chk_b1, chk_b2, chk_b3, chk_b4, chk_b5;
  reg [15:0] exp_a1, exp_a2, exp_a3, exp_a4, exp_a5, exp_b1, exp_b2, exp_b3, exp_b4, exp_b5;
  wire       sbad_lo_a = chk_a5 & (doa_s[7:0] != exp_a5[7:0]);
  wire       sbad_hi_a = chk_a5 & (doa_s[15:8] != exp_a5[15:8]);
  wire       sbad_lo_b = chk_b5 & (dob_s[7:0] != exp_b5[7:0]);
  wire       sbad_hi_b = chk_b5 & (dob_s[15:8] != exp_b5[15:8]);
  reg        s_err;   // any of them, a cycle later (for the pass total)
  // Trace of the first stress error in a block: the read's word follows
  // it down the pipeline; hist holds the decoded operations of the last 16
  // cycles (newest in hist[0]), frozen at the error.
  reg [3:0]  sa_a1, sa_a2, sa_a3, sa_a4, sa_a5, sa_b1, sa_b2, sa_b3, sa_b4, sa_b5;
  reg [47:0] hist [0:15];
  reg        frozen;
  reg        e_port;            // 0 A, 1 B
  reg [3:0]  e_word;
  reg [15:0] e_exp, e_got;
  wire       a_bad = sbad_lo_a | sbad_hi_a;
  wire       any_bad = a_bad | sbad_lo_b | sbad_hi_b;
  wire [47:0] o_entry = {o_rd_a, o_wr_a, o_sa_a, o_be_a, o_d_a, o_rd_b, o_wr_b, o_sa_b, o_be_b, o_d_b};
  integer h;
  always @(posedge clk) begin
    // the shadow takes the init words and the decoded stress writes
    if (sinit) shadow[scnt[3:0]] <= rnd[15:0];
    if (o_wr_a) begin
      if (o_be_a[0]) shadow[o_sa_a][7:0] <= o_d_a[7:0];
      if (o_be_a[1]) shadow[o_sa_a][15:8] <= o_d_a[15:8];
    end
    if (o_wr_b) begin
      if (o_be_b[0]) shadow[o_sa_b][7:0] <= o_d_b[7:0];
      if (o_be_b[1]) shadow[o_sa_b][15:8] <= o_d_b[15:8];
    end
    chk_a1 <= o_rd_a;
    chk_b1 <= o_rd_b;
    exp_a1 <= shadow[o_sa_a];   // (no write to that word this cycle)
    exp_b1 <= shadow[o_sa_b];
    chk_a2 <= chk_a1; chk_a3 <= chk_a2; chk_a4 <= chk_a3; chk_a5 <= chk_a4;
    chk_b2 <= chk_b1; chk_b3 <= chk_b2; chk_b4 <= chk_b3; chk_b5 <= chk_b4;
    exp_a2 <= exp_a1; exp_a3 <= exp_a2; exp_a4 <= exp_a3; exp_a5 <= exp_a4;
    exp_b2 <= exp_b1; exp_b3 <= exp_b2; exp_b4 <= exp_b3; exp_b5 <= exp_b4;
    s_err <= sbad_lo_a | sbad_hi_a | sbad_lo_b | sbad_hi_b;
    sa_a1 <= o_sa_a; sa_a2 <= sa_a1; sa_a3 <= sa_a2; sa_a4 <= sa_a3; sa_a5 <= sa_a4;
    sa_b1 <= o_sa_b; sa_b2 <= sa_b1; sa_b3 <= sa_b2; sa_b4 <= sa_b3; sa_b5 <= sa_b4;
    if (rst | clr_s) frozen <= 1'b0;
    else if (!frozen && any_bad) begin
      frozen <= 1'b1;
      e_port <= !a_bad;
      e_word <= a_bad ? sa_a5 : sa_b5;
      e_exp  <= a_bad ? exp_a5 : exp_b5;
      e_got  <= a_bad ? doa_s : dob_s;
    end
    if (!frozen && !any_bad) begin
      hist[0] <= o_entry;
      for (h = 1; h < 16; h = h + 1) hist[h] <= hist[h - 1];
    end
    if (rst | clr_s) begin
      s_lo_a <= 0; s_hi_a <= 0; s_lo_b <= 0; s_hi_b <= 0;
    end else begin
      if (sbad_lo_a) s_lo_a <= s_lo_a + 16'd1;
      if (sbad_hi_a) s_hi_a <= s_hi_a + 16'd1;
      if (sbad_lo_b) s_lo_b <= s_lo_b + 16'd1;
      if (sbad_hi_b) s_hi_b <= s_hi_b + 16'd1;
    end
  end

  // ------------------------------------------------------------------
  // Report lines: '#' in the template is the next hex digit of the line's
  // fields (first digit = top nibble). Each character is fetched into
  // t_cur a cycle before it goes out.
  // ------------------------------------------------------------------
  localparam integer LB = 169;
  localparam [8*LB-1:0] T_BLK = "blk ## A: full #### lo01 #### hi01 #### lo10 #### hi10 #### be00 #### | B: full #### lo01 #### hi01 #### lo10 #### hi10 #### be00 #### | stress A #### #### B #### ####\015\n";
  localparam integer LS = 27;
  localparam [8*LS-1:0] T_SUM = "pass #### errors ########\015\n";
  localparam integer LE = 98;
  localparam [8*LE-1:0] T_ERR = "  first stress error: port # word # expected #### got ####; ops, newest first (h4 is that read):\015\n";
  localparam integer LT = 68;
  localparam [8*LT-1:0] T_HIST = "  h# A: op # word # be # data #### | B: op # word # be # data ####\015\n";
  localparam integer LP = 166;
  localparam [8*LP-1:0] T_PAIR = "pairs kind # byte #   from 0: to 0 ### 1 ### 2 ### 3 ###  from 1: to 0 ### 1 ### 2 ### 3 ###  from 2: to 0 ### 1 ### 2 ### 3 ###  from 3: to 0 ### 1 ### 2 ### 3 ###\015\n";
  localparam integer LH = 58;
  localparam [8*LH-1:0] T_HELLO = "bsram_be: 26 x DPB 1024x16, byte enables AD[1:0], ## MHz\015\n";

  wire [263:0] f_blk = {3'b000, blk,
                        c_full[0], c_lo01[0], c_hi01[0], c_lo10[0], c_hi10[0], c_00[0],
                        c_full[1], c_lo01[1], c_hi01[1], c_lo10[1], c_hi10[1], c_00[1],
                        s_lo_a, s_hi_a, s_lo_b, s_hi_b};
  wire [7:0]   mhz_bcd = `CLK_MHZ == 27 ? 8'h27 : `CLK_MHZ == 36 ? 8'h36 : 8'h72;
  wire [263:0] f_sum = {pass, total, 216'd0};
  wire [263:0] f_hello = {mhz_bcd, 256'd0};
  reg  [3:0]   hk;   // history line being printed
  reg  [2:0]   pl;   // transition line being printed: {kind, byte}
  wire [191:0] pc_row;
  genvar pr_i;
  generate
    for (pr_i = 0; pr_i < 16; pr_i = pr_i + 1) begin : pcr
      localparam [3:0] PQ = pr_i;
      assign pc_row[191 - 12 * pr_i -: 12] = pl[0] ? prc_hi[{pl[2:1], PQ}] : prc_lo[{pl[2:1], PQ}];
    end
  endgenerate
  wire [263:0] f_pair = {2'b00, pl[2:1], 3'b000, pl[0], pc_row, 64'd0};
  wire [47:0]  he = hist[hk];
  wire [263:0] f_err  = {e_port ? 4'hB : 4'hA, e_word, e_exp, e_got, 224'd0};
  // op: 0 idle, 1 read, 2 write
  wire [263:0] f_hist = {hk, 2'b00, he[46], he[47], he[45:42], 2'b00, he[41:40], he[39:24],
                         2'b00, he[22], he[23], he[21:18], 2'b00, he[17:16], he[15:0], 204'd0};

  reg  [7:0] ci;     // character index (of t_cur)
  reg  [7:0] ni;     // 0: the line's fields still to be loaded into fsh
  reg  [2:0] tsel;   // 0 hello, 1 block, 2 summary, 3 trace header, 4 trace line, 5 transitions
  reg  [7:0] t_cur;  // the template's character ci
  reg  [7:0] h_cur;  // the next hex digit (used if t_cur is '#')
  reg        t_ok;   // t_cur, h_cur fetched
  reg        t_end;  // ... and ci was the end of the template
  reg  [263:0] fsh;  // the line's fields, shifted out a digit at a time
  wire [7:0] tlen = tsel == 3'd0 ? LH : tsel == 3'd1 ? LB : tsel == 3'd2 ? LS : tsel == 3'd3 ? LE :
                    tsel == 3'd4 ? LT : LP;
  wire [7:0] t_next = tsel == 3'd0 ? T_HELLO[8*(LH-1-ci) +: 8] :
                      tsel == 3'd1 ? T_BLK[8*(LB-1-ci) +: 8] :
                      tsel == 3'd2 ? T_SUM[8*(LS-1-ci) +: 8] :
                      tsel == 3'd3 ? T_ERR[8*(LE-1-ci) +: 8] :
                      tsel == 3'd4 ? T_HIST[8*(LT-1-ci) +: 8] : T_PAIR[8*(LP-1-ci) +: 8];
  wire [263:0] fld = tsel == 3'd2 ? f_sum : tsel == 3'd0 ? f_hello : tsel == 3'd3 ? f_err :
                     tsel == 3'd4 ? f_hist : tsel == 3'd5 ? f_pair : f_blk;
  wire [3:0] nib  = fsh[263:260];
  wire [7:0] hexc = nib < 4'd10 ? 8'h30 + nib : 8'h57 + nib;   // 0-9, a-f

  integer k;
  always @(posedge clk) begin
    tx_go <= 1'b0;
    clr_s <= 1'b0;
    clr_p <= 1'b0;
    if (rst) begin
      state <= S_HELLO;
      tsel <= 3'd0;
      ci <= 8'd0;
      ni <= 8'd0;
      t_ok <= 1'b0;
      blk <= 5'd0;
      wp <= 1'b0;
      ph <= 3'd0;
      addr <= 10'd0;
      pass <= 16'd0;
      total <= 32'd0;
      any_err <= 1'b0;
      rnd <= 64'h9E3779B97F4A7C15;
    end else begin
      case (state)
        S_HELLO, S_PRINT, S_SUM, S_TRACE: begin
          // print template tsel, then go on: fetch character ci (and the
          // next digit), then send it, or at the end move on
          if (!t_ok) begin
            if (ci == 8'd0 && ni == 8'd0) begin
              fsh <= fld;     // a new line: its fields
              ni <= 8'd1;
            end else begin
              t_cur <= t_next;
              h_cur <= hexc;
              t_end <= ci == tlen;
              t_ok <= 1'b1;
            end
          end else if (t_end) begin
            t_ok <= 1'b0;
            ci <= 8'd0;
            ni <= 8'd0;
            if (state == S_PRINT && frozen) begin
              state <= S_TRACE;   // the block's first stress error
              tsel <= 3'd3;
              hk <= 4'd0;
            end else if (state == S_TRACE && tsel == 3'd3) begin
              tsel <= 3'd4;
            end else if (state == S_TRACE && hk != 4'd15) begin
              hk <= hk + 4'd1;
            end else if (state == S_PRINT || state == S_TRACE) begin
              // next block (counters cleared), or the pass summary
              clr_s <= 1'b1;   // (clears the directed counts too)
              if (blk == N - 1) begin
                state <= S_SUM;
                tsel <= 3'd2;
                pass <= pass + 16'd1;
              end else begin
                blk <= blk + 5'd1;
                state <= S_W;
              end
            end else if (state == S_SUM && tsel == 3'd2) begin
              tsel <= 3'd5;   // the transition counts, 8 lines
              pl <= 3'd0;
            end else if (state == S_SUM && tsel == 3'd5 && pl != 3'd7) begin
              pl <= pl + 3'd1;
            end else begin
              if (state == S_SUM) clr_p <= 1'b1;
              blk <= 5'd0;
              state <= S_W;
            end
          end else if (!tx_busy && !tx_go) begin
            tx_char <= t_cur == "#" ? h_cur : t_cur;
            if (t_cur == "#") fsh <= fsh << 4;
            tx_go <= 1'b1;
            ci <= ci + 8'd1;
            t_ok <= 1'b0;
          end
        end
        S_W: begin   // one word written per cycle
          addr <= addr + 10'd1;
          if (addr == 10'd1023) begin
            ph <= ph + 3'd1;
            state <= S_RD;
          end
        end
        S_RD: begin   // address on both ports; the data is checked 5 cycles later
          wait_n <= 2'd3;
          state <= S_WAIT;
        end
        S_WAIT: begin
          wait_n <= wait_n - 2'd1;
          if (wait_n == 2'd0) state <= S_CMP;
        end
        S_CMP: begin
          // (the counts are made a cycle later, from the ev_* registers)
          addr <= addr + 10'd1;
          if (addr != 10'd1023) state <= S_RD;
          else if (ph != 3'd7) begin
            ph <= ph + 3'd1;
            state <= S_W;
          end else state <= S_NEXT;
        end
        S_NEXT: begin   // this writing port done: the other one, or the stress test
          ph <= 3'd0;
          if (!wp) begin
            wp <= 1'b1;
            state <= S_W;
          end else begin
            wp <= 1'b0;
            pidx <= 6'd0;
            tpi <= 6'd0;
            pst <= 4'd0;
            state <= S_PAIR;
          end
        end
        S_PAIR: begin   // the transition test, per writing port
          pst <= pst + 4'd1;
          if (pst == 4'd15) begin
            tpi <= tpi + 6'd1;
            if (tpi == 6'd63) begin
              pidx <= pidx + 6'd1;
              if (pidx == 6'd63) begin
                pidx <= 6'd0;
                if (!wp) wp <= 1'b1;
                else begin
                  wp <= 1'b0;
                  scnt <= 17'd0;
                  state <= S_SINIT;
                end
              end
            end
          end
        end
        S_SINIT: begin   // 16 words through port A (the shadow: see above)
          rnd <= rnd_next;
          scnt <= scnt + 17'd1;
          if (scnt[3:0] == 4'd15) begin
            scnt <= STRESS;
            state <= S_STRESS;
          end
        end
        S_STRESS: begin
          rnd <= rnd_next;
          scnt <= scnt - 17'd1;
          if (scnt == 17'd1) begin
            scnt <= 17'd10;  // the last operations through the pipeline
            state <= S_DRAIN;
          end
        end
        S_DRAIN: begin   // (10 cycles: the pipeline is 7 deep)
          scnt <= scnt - 17'd1;
          if (scnt == 17'd1) begin
            tsel <= 3'd1;
            state <= S_PRINT;
          end
        end
        default: state <= S_HELLO;
      endcase
      // errors into the pass total (stress: the checks run on into S_DRAIN)
      if (s_err | (ev_v & (ev_lo | ev_hi)) | pb_lo | pb_hi) begin
        total <= total + 32'd1;
        any_err <= 1'b1;
      end
    end
  end

  // Directed counts, from the check results a cycle later.
  always @(posedge clk) begin
    ev_v  <= !rst && state == S_CMP;
    ev_lo <= bad_lo;
    ev_hi <= bad_hi;
    ev_ph <= ph;
    ev_wp <= wp;
    if (rst | clr_s) begin
      for (k = 0; k < 2; k = k + 1) begin
        c_full[k] <= 0; c_lo01[k] <= 0; c_hi01[k] <= 0; c_lo10[k] <= 0; c_hi10[k] <= 0; c_00[k] <= 0;
      end
    end else if (ev_v) begin
      case (ev_ph)
        3'd1: if ((ev_lo | ev_hi)) c_full[ev_wp] <= c_full[ev_wp] + 16'd1;
        3'd3: begin
          if (ev_lo) c_lo01[ev_wp] <= c_lo01[ev_wp] + 16'd1;
          if (ev_hi) c_hi01[ev_wp] <= c_hi01[ev_wp] + 16'd1;
        end
        3'd5: begin
          if (ev_lo) c_lo10[ev_wp] <= c_lo10[ev_wp] + 16'd1;
          if (ev_hi) c_hi10[ev_wp] <= c_hi10[ev_wp] + 16'd1;
        end
        default: if ((ev_lo | ev_hi)) c_00[ev_wp] <= c_00[ev_wp] + 16'd1;
      endcase
    end
  end

  // Transition test checks, counted a cycle later.
  wire [15:0] pdo  = wp ? dob_s : doa_s;
  wire        pchk = pairing & pst == 4'd13;
  integer pr;
  always @(posedge clk) begin
    pb_lo <= pchk & (pdo[7:0] != xexp[7:0]);
    pb_hi <= pchk & (pdo[15:8] != xexp[15:8]);
    pb_idx <= pidx;
    if (rst | clr_p) pclr <= 7'd0;
    else if (!pclr[6]) pclr <= pclr + 7'd1;
    if (!pclr[6]) begin
      prc_lo[pclr[5:0]] <= 12'd0;
      prc_hi[pclr[5:0]] <= 12'd0;
    end else begin
      if (pb_lo) prc_lo[pb_idx] <= prc_lo[pb_idx] + 12'd1;
      if (pb_hi) prc_hi[pb_idx] <= prc_hi[pb_idx] + 12'd1;
    end
  end

  // LEDs (active low): 0 toggles per pass, 1 after any error.
  assign led = {4'b1111, ~any_err, ~pass[0]};
endmodule
