module hyperram #(
  // 1: the line requests come from system_clk / 2 (psram_bridge's SYNC):
  // no synchronizer on line_req_toggle.
  parameter LINE_SYNC = 0
) (
  // Clocks and reset
	input wire system_clk,
	input wire memory_clk,
  input wire rst_n,

`define CLK_DELAY 67
`define READ_DELAY 71

//`define DEBUG_SIGNAL
`ifdef DEBUG_SIGNAL
  // Debug (die 0 only)
  output reg [31:0]rd_data[0:11],
  output reg [47:0]rd_rwds,
`endif

  // DMA requests (system_clk domain, from the video/audio engine): copy
  // dma_count 256-byte blocks (128 bytes per die) from PSRAM block
  // dma_psram_block (interleaved byte address >> 8) on into hr_ram blocks
  // dma_hr_block on. dma_start is a one-cycle pulse, only accepted while
  // !dma_busy; dma_busy stays high until the last block is in hr_ram. The
  // blocks go out as separate bursts, so cache line requests can get in
  // between them.
  input wire dma_start,
  input wire [15:0] dma_psram_block,
  input wire [4:0] dma_hr_block,
  input wire [4:0] dma_count,
  output reg dma_busy,

  // Cache line requests (from psram_bridge, CPU clock domain): a request
  // is pending while line_req_toggle != line_ack_toggle. line_write and
  // line_addr (PSRAM byte address bits 23:6) are stable from before the
  // toggle until the ack. A line is 64 bytes, 32 per die: one 8-beat burst,
  // with CS# raised early (no CR0 change needed, since an aligned 32-byte
  // per-die line never reaches the 128-byte wrap boundary). Line bursts use
  // the same vr_* port as commands, with burst_line high: the data goes
  // to/from the bridge's line buffers (index vr_addr[2:0]) instead of
  // hr_ram. line_ack_toggle flips once a write-back's line has been read
  // from wbuf, and as soon as a refill's data starts arriving in rbuf (see
  // the line request completion below).
  input wire line_req_toggle,
  input wire line_write,
  input wire [17:0] line_addr,
  output reg line_ack_toggle,
  output reg burst_line,

  // Video RAM interface: one 64-bit word per system_clk cycle, bits 31:0
  // to/from die 0 and bits 63:32 to/from die 1. A burst is 32 words
  // (128 bytes per die, 256 bytes in total).
  output reg vr_read,
  output reg vr_write,
  output reg [9:0]vr_addr,
  input wire [63:0]vr_read_data,
  output reg [63:0]vr_write_data,

  // Embedded HyperRAM: both dies of the GW1NR-9, driven in lockstep (same
  // command, address and timing), each with its own 8-bit DQ bus.
  output     [1:0]  O_hpram_ck,
  output     [1:0]  O_hpram_ck_n,
  output     [1:0]  O_hpram_cs_n,
  output     [1:0]  O_hpram_reset_n,
  inout      [15:0] IO_hpram_dq,
  inout      [1:0]  IO_hpram_rwds
);

  reg [5:0]phase;

  reg [63:0] dq_in_d;

  reg [63:0] sel_dq_out;
  reg [5:0] rpt_cnt;

  reg [21:0] sel_addr;
  reg [21:0] addr_reg;

  reg [6:0]vr_addr_top_reg;


  reg [1:0]cmd;
  reg cmd_en;

  reg [2:0]vr_bank;

  always @(*) begin
    if (phase == 6'd0) begin
      // CA[47] = read, CA[46] = register space, CA[45] = burst type. On the
      // W955D8MBYA CA[45] is 0 for memory (wrapped burst, length from
      // CR0[1:0]) and 1 for register accesses; there is no linear burst.
      sel_dq_out = {2{addr_reg[10:3], addr_reg[18:11], 5'b0, addr_reg[21:19], cmd[1:0], cmd[0], 5'b00000}};
    end else if (phase == 6'd1) begin
      // Don't bother with addr_reg here, the only case we have something in these bottom bits
      // is when reading or writing registers.
      sel_dq_out = {2{CR0_VALUE[7:0], CR0_VALUE[15:8], 5'b0, addr_reg[2:0], 8'b0}};
    end else begin
      sel_dq_out = vr_read_data;
    end
  end

  // CR0, written to both dies once after reset: 6-clock fixed 2x latency
  // (as the default), 128-byte wrapped bursts (default 32). Memory bursts
  // always wrap on this chip, so 256-byte (128 per die) bursts need it.
  localparam [15:0] CR0_VALUE = 16'h8f1c;
  reg init_pending;
  // The first access has to wait tVCS = 150 us after RESET# goes high
  // (datasheet Table 11); this also keeps it clear of the SERDES reset.
  // 16384 cycles at 74.25 MHz = 220 us. Nothing else is issued before it.
  reg [13:0] init_wait;
  reg init_ready;   // a flop: the arbitration below tests it every cycle

  // DMA engine state: next block to fetch and blocks left to issue.
  reg [15:0] dma_psram_cur;
  reg [4:0]  dma_hr_cur;
  reg [4:0]  dma_left;
  wire dma_accept = dma_start && !dma_busy;

  // Config reg 0 default: 16'h8f2f  (8f1c)
  // Config reg 1 default: 16'ffc1

  reg sequencer_active;

  // Line request handshake (see ports). line_busy covers an accepted
  // request until its ack.
  reg [1:0] line_req_s;
  reg line_busy;
  always @(posedge system_clk or negedge rst_n) begin
    if (~rst_n) line_req_s <= 2'b00;
    else        line_req_s <= {line_req_s[0], line_req_toggle};
  end
  // With LINE_SYNC (the CPU on system_clk / 2) the request goes through
  // one flop instead of the synchronizer's two: straight from the CPU it
  // had only one 72 MHz period to reach the arbitration logic. (line_addr
  // and line_write change with the toggle, so they are stable a cycle
  // before the flopped toggle is seen.)
  wire line_req_now = LINE_SYNC ? line_req_s[0] : line_req_s[1];
  wire line_pending = (line_req_now != line_ack_toggle) && !line_busy;

  // Per-command burst shape: seq_line = this command is a cache line
  // transfer (8 data cycles), otherwise a full 32-cycle burst. The chip
  // takes write data from CK clock 2 + 2 * latency = 14, i.e. phase 7, for
  // as long as CK runs, so writes stop CK one phase before reads do: with
  // CS# off at phase 16/40, a write stored one extra cycle (4 bytes per
  // die), which the 128-byte wrap put onto the start of the wrap group --
  // harmless for full bursts (same data), but it clobbered the first beat
  // of the group's first line after a write-back of its last line.
  reg seq_line;
  wire seq_write = !cmd[1];
  wire [5:0] cs_off_phase = seq_line ? (seq_write ? 6'd15 : 6'd16)
                                     : (seq_write ? 6'd39 : 6'd40);
  wire [5:0] last_phase   = seq_line ? 6'd19 : 6'd43;

  always @(posedge system_clk or negedge rst_n) begin
    if (~rst_n) begin
      ck_out_en <= 1'b0;      // Enable clock.
      cs_n <= 1'b1;           // Chip select
      rwds_out <= 1'b0;       // RWDS output
      rwds_oe_n <= 1'b1;      // RWDS out enable  
      dq_oe_n <= 1'b1;        // DQ out enable
      dq_out <= 64'b0;        // DQ output
      addr_reg[21:0] <= 0;

      vr_addr_top_reg <= 7'b0;
      rpt_cnt <= 6'd0;

      phase <= 6'd0;
      sequencer_active <= 1'b0;

      init_pending <= 1'b1;
      init_wait <= 14'd0;
      init_ready <= 1'b0;
      dma_left <= 5'd0;
      cmd_en <= 1'b0;
      start_burst <= 1'b0;
      seq_line <= 1'b0;

    end else begin
      // A new DMA request (only accepted while idle, so dma_left is 0 and
      // not being decremented below).
      if (!init_ready) init_wait <= init_wait + 1'b1;
      if (&init_wait) init_ready <= 1'b1;

      if (dma_accept) begin
        dma_psram_cur <= dma_psram_block;
        dma_hr_cur <= dma_hr_block;
        dma_left <= dma_count;
      end

      // Word reconstruction, calibrated against this board. With the
      // test pattern {i, 0x5A, i, ~i} written to hr_ram, bursting it to
      // the chip and back and reconstructing as {dq_in_d[15:0],
      // dq_in_d[31:16]} returned {i-1, 0x5A, i, ~i}: bytes 0..2 correct,
      // byte 3 one system_clk cycle early (i.e. the read stream is skewed
      // by one byte, as the controller's first version assumed).
      // So bytes 0..2 come from the delayed copy dq_in_d and byte 3 from
      // the same lane of the following cycle's dq_in. The first word of
      // a read burst still has a stray byte (its first half-word is
      // captured before the data arrives) -- not yet fixed.
      dq_in_d <= dq_in;
      // Same reconstruction for each die's 32-bit half.
      vr_write_data <= {dq_in[47:32], dq_in_d[63:48], dq_in[15:0], dq_in_d[31:16]};
      dq_out <= sel_dq_out;

      if (!sequencer_active) begin
        cs_n <= 1'b1;
        ck_out_en <= 1'b0;
        rwds_oe_n <= 1'b1;
        dq_oe_n <= 2'b00;
        phase <= 6'd0;

        // The CR0 write goes first, then cache line requests (the CPU is
        // stalled on them), then DMA blocks.
        if (!init_ready) begin
          // Wait out tVCS.
        end else if (init_pending) begin
          cmd <= 2'b01;
          rpt_cnt <= 6'd0;
          addr_reg <= {16'h0020, 6'b000000};   // CR0: CA 60 00 01 00 00 00
          vr_addr_top_reg <= 7'd0;
          seq_line <= 1'b0;
          sequencer_active <= 1'b1;
          cs_n <= 1'b0;
          init_pending <= 1'b0;
        end else if (line_pending) begin
          cmd <= line_write ? 2'b00 : 2'b10;
          rpt_cnt <= 6'd0;
          // Per-die half-word address: 64 half-words per 256-byte block,
          // 16 per 64-byte line.
          addr_reg <= {line_addr, 4'b0000};
          vr_addr_top_reg <= 7'd0;
          seq_line <= 1'b1;
          sequencer_active <= 1'b1;
          cs_n <= 1'b0;
        end else if (dma_left != 5'd0) begin
          cmd <= 2'b10;
          rpt_cnt <= 6'd0;
          addr_reg <= {dma_psram_cur, 6'b000000};
          vr_addr_top_reg <= {2'b00, dma_hr_cur};
          seq_line <= 1'b0;
          sequencer_active <= 1'b1;
          // CS# goes low one system_clk cycle before phase 0 starts CK,
          // to meet tCSS (CS# low to first CK rising edge >= 2 ns);
          // dropping it together with the first CK edge only gave
          // CLK_DELAY of setup.
          cs_n <= 1'b0;
          dma_psram_cur <= dma_psram_cur + 1'b1;
          dma_hr_cur <= dma_hr_cur + 1'b1;
          dma_left <= dma_left - 1'b1;
        end
      end else begin
        if (phase == 1 && cmd == 2'b01) begin
          sequencer_active <= 1'b0;
          phase <= 6'd0;
        end else if (phase != last_phase) begin
          phase <= phase + 1'b1;
        end else begin
          phase <= 6'd0;
          if (rpt_cnt == 0) begin
            sequencer_active <= 1'b0;
          end else begin
            rpt_cnt <= rpt_cnt - 1'b1;
            cs_n <= 1'b0;   // next burst: same tCSS lead as above
          end
          vr_addr_top_reg <= vr_addr_top_reg + 2'd1;
          addr_reg[21:6] <= addr_reg[21:6] + 1'b1;
        end
      
        case (phase)
          6'd0: begin
            cs_n <= 1'b0;
            ck_out_en <= 1'b1;
            rwds_oe_n <= 1'b1;
            dq_oe_n <= 2'b00;
          end
          6'd1: begin
            if (cmd == 2'b01) begin
              dq_oe_n <= 2'b00;
            end else begin
              dq_oe_n <= 2'b10;
            end
          end
          6'd2: begin
            dq_oe_n <= 2'b11;
          end
          6'd4: begin
            if (cmd[1] == 1'b0) begin
              start_burst <= 1'b1;
            end
          end
          6'd5: begin
            // This reads in the first part of the command
  `ifdef DEBUG_SIGNAL
            rd_rwds[3:0] <= rwds_in;
            rd_data[0] <= dq_in;
  `endif
            start_burst <= 1'b0;
          end
          6'd6: begin
            // This reads in the second part of the command
  `ifdef DEBUG_SIGNAL
            rd_rwds[7:4] <= rwds_in;
            rd_data[1] <= dq_in;
  `endif
          end
          6'd7: begin
            if (cmd[1] == 1'b0) begin
              // Write command.
              dq_oe_n <= 2'b00;
              rwds_oe_n <= 1'b0;
            end
          end
          6'd12: begin
  `ifdef DEBUG_SIGNAL
            rd_rwds[11:8] <= rwds_in;
            rd_data[2] <= dq_in;
  `endif
          end
          6'd13: begin
  `ifdef DEBUG_SIGNAL
            rd_rwds[15:12] <= rwds_in;
            rd_data[3] <= dq_in;
  `endif
            if (cmd[1] == 1'b1) begin
              start_burst <= 1'b1;
            end
          end
          6'd14: begin
  `ifdef DEBUG_SIGNAL
            rd_rwds[19:16] <= rwds_in;
            rd_data[4] <= dq_in;
  `endif
            start_burst <= 1'b0;
          end
          6'd16: begin
  `ifdef DEBUG_SIGNAL
            rd_rwds[23:20] <= rwds_in;
            rd_data[5] <= dq_in;
  `endif
          end
          6'd17: begin
  `ifdef DEBUG_SIGNAL
            rd_rwds[27:24] <= rwds_in;
            rd_data[6] <= dq_in;
  `endif
          end
          6'd18: begin
  `ifdef DEBUG_SIGNAL
            rd_rwds[31:28] <= rwds_in;
            rd_data[7] <= dq_in;
  `endif
          end
          6'd19: begin
  `ifdef DEBUG_SIGNAL
            rd_rwds[35:32] <= rwds_in;
            rd_data[8] <= dq_in;
  `endif
          end
          6'd20: begin
  `ifdef DEBUG_SIGNAL
            rd_rwds[39:36] <= rwds_in;
            rd_data[9] <= dq_in;
  `endif
          end
          6'd21: begin
  `ifdef DEBUG_SIGNAL
            rd_rwds[43:40] <= rwds_in;
            rd_data[10] <= dq_in;
  `endif
          end
          6'd22: begin
  `ifdef DEBUG_SIGNAL
            rd_rwds[47:44] <= rwds_in;
            rd_data[11] <= dq_in;
  `endif
          end
        endcase

        if (phase == cs_off_phase) begin
          // The command has completed, disable the RAM.
          cs_n <= 1'b1;
          ck_out_en <= 1'b0;
          dq_oe_n <= 2'b11;
          rwds_oe_n <= 1'b1;
        end
      end
    end
  end

  reg start_burst;
  reg burst_active;

  // The burst's shape is latched at its start: a read burst's writes into
  // video RAM / the line buffer run a few cycles past the end of its
  // command, possibly into the next command.
  always @(posedge system_clk or negedge rst_n) begin
    if (~rst_n) begin
      vr_read <= 1'd0;
      vr_write <= 1'd0;
      vr_addr <= 12'd0;
      burst_active <= 1'b0;
      burst_line <= 1'b0;
    end else begin
      if (start_burst) begin
        burst_active <= 1'b1;
        burst_line <= seq_line;
        vr_addr <= {vr_addr_top_reg[4:0], 5'b00000};

        if (cmd[1] == 1'b1) begin  
          // Read command
          vr_write <= 1'b1;
          vr_read <= 1'b0;
        end else begin
          // Write command
          vr_write <= 1'b0;
          vr_read <= 1'b1;
        end

      end else if (burst_active) begin
        vr_addr[4:0] <= vr_addr[4:0] + 1'b1;
        if (burst_line ? vr_addr[2:0] == 3'd7 : vr_addr[4:0] == 5'd31) begin
          burst_active <= 1'b0;
          vr_read <= 1'b0;
          vr_write <= 1'b0;
        end
      end else begin
        vr_read <= 1'b0;
        vr_write <= 1'b0;
      end
    end
  end


  // DMA request acceptance and completion: busy from dma_start until the
  // last block has been issued and its burst has finished writing hr_ram.
  always @(posedge system_clk or negedge rst_n) begin
    if (~rst_n) begin
      dma_busy <= 1'b0;
    end else if (!dma_busy) begin
      if (dma_start) dma_busy <= 1'b1;
    end else if (dma_left == 5'd0 && !(sequencer_active && !seq_line && cmd == 2'b10) &&
                 !burst_active && !start_burst && !dma_accept) begin
      dma_busy <= 1'b0;
    end
  end

  // Line request completion: same idea as above, the ack flips once the
  // line's burst has finished moving data.
  reg line_done_pending;
  always @(posedge system_clk or negedge rst_n) begin
    if (~rst_n) begin
      line_busy <= 1'b0;
      line_done_pending <= 1'b0;
      line_ack_toggle <= 1'b0;
    end else begin
      // Exactly when the sequencer takes the request (the CR0 wait and
      // write come first).
      if (!sequencer_active && line_pending && init_ready && !init_pending)
        line_busy <= 1'b1;
      // A refill is acked as its data starts: the burst then writes one
      // word per cycle into the bridge's rbuf, faster than the bridge (two
      // CPU cycles of synchronizer later) reads one per CPU cycle, so the
      // bridge answers its beats while the rest of the line arrives. (The
      // sequencer stays busy until the command ends, so a new request
      // can't start early.)
      if (start_burst && seq_line && cmd[1]) begin
        line_busy <= 1'b0;
        line_ack_toggle <= ~line_ack_toggle;
      end
      // A write-back is acked when its burst has read the whole of wbuf.
      if (sequencer_active && seq_line && !cmd[1] && phase == last_phase)
        line_done_pending <= 1'b1;
      else if (line_done_pending && !burst_active && !start_burst) begin
        line_done_pending <= 1'b0;
        line_busy <= 1'b0;
        line_ack_toggle <= ~line_ack_toggle;
      end
    end
  end

  // ---------------------------------------------------------------------------
  //
  // Input / output management
  //
  // ---------------------------------------------------------------------------

  // Reset sync
  reg rst_0, rst_1, rst;
  always @(posedge system_clk or negedge rst_n) begin
    if (~rst_n) begin
      rst_0 <= 1'b1;
      rst_1 <= 1'b0;
      rst <= 1'b0;
    end else begin
      rst_0 <= 1'b0;
      rst_1 <= rst_0;
      rst <= rst_1;
    end
  end
    
  

  // The following signals are delayed via OSER4s. They are shared by
  // both dies; each die's pins get their own OSER4/IDES4/IODELAY (those
  // live in the pin's IO block).
  reg ck_out_en;      // Enable clock.
  reg cs_n;           // Chip select
  reg rwds_out;       // RWDS output
  reg rwds_oe_n;      // RWDS out enable
  wire [7:0]rwds_in;  // RWDS input (deserialized), 4 bits per die
  reg [1:0]dq_oe_n;   // DQ out enable
  reg [63:0] dq_out;  // DQ output, 32 bits per die
  wire [63:0] dq_in;  // DQ input (deserialized), 32 bits per die

  genvar d, i;
  generate
    for (d = 0; d < 2; d++) begin: die_

      // Clocks.
      wire ck_ser, ck_ser_d, ck_ser_df;
      wire ck_n_ser, ck_n_ser_d, ck_n_ser_df;
      wire ck_oe, ck_n_oe;   // Ignored, always output.
      OBUF obuf_ck (
        .I(ck_ser_d),
        .O(O_hpram_ck[d])
      );
      OBUF obuf_ck_n (
        .I(ck_n_ser_d),
        .O(O_hpram_ck_n[d])
      );
      IODELAY #(.C_STATIC_DLY(`CLK_DELAY)) ck_delay (
        .DI(ck_ser),
        .SETN(1'b0),
        .SDTAP(1'b0),
        .VALUE(1'b0),
        .DO(ck_ser_d),
        .DF(ck_ser_df)    // Don't care.
      );
      IODELAY #(.C_STATIC_DLY(`CLK_DELAY)) ck_n_delay (
        .DI(ck_n_ser),
        .SETN(1'b0),
        .SDTAP(1'b0),
        .VALUE(1'b0),
        .DO(ck_n_ser_d),
        .DF(ck_n_ser_df)    // Don't care.
      );
      OSER4#(.HWL("false")) ck_oser4 (
        .D0(ck_out_en),
        .D1(1'b0),
        .D2(ck_out_en),
        .D3(1'b0),
        .PCLK(system_clk),
        .FCLK(memory_clk),
        .RESET(rst),
        .TX0(1'b0),
        .TX1(1'b0),
        .Q0(ck_ser),
        .Q1(ck_oe)
      );
      OSER4#(.HWL("false")) ck_n_oser4 (
        .D0(~ck_out_en),
        .D1(1'b1),
        .D2(~ck_out_en),
        .D3(1'b1),
        .PCLK(system_clk),
        .FCLK(memory_clk),
        .RESET(rst),
        .TX0(1'b0),
        .TX1(1'b0),
        .Q0(ck_n_ser),
        .Q1(ck_n_oe)
      );

      // Chip select
      wire cs_n_ser, cs_n_oe;
      OBUF obuf_cs_n (
        .I(cs_n_ser),
        .O(O_hpram_cs_n[d])
      );
      OSER4#(.HWL("false")) cs_n_oser4 (
        .D0(cs_n),
        .D1(cs_n),
        .D2(cs_n),
        .D3(cs_n),
        .PCLK(system_clk),
        .FCLK(memory_clk),
        .RESET(rst),
        .TX0(1'b0),
        .TX1(1'b0),
        .Q0(cs_n_ser),
        .Q1(cs_n_oe)   // Ignored, always output.
      );

      // Reset. This one is simply wired through.
      OBUF obuf_reset_n (
        .I(rst_n),
        .O(O_hpram_reset_n[d])
      );

      // RWDS
      wire rwds_out_ser, rwds_out_ser_oe_n, rwds_in_ser;
      wire rwds_in_ser_d, rwds_in_ser_df;
      IOBUF rwds_iobuf (
        .I(rwds_out_ser),
        .OEN(rwds_out_ser_oe_n),
        .IO(IO_hpram_rwds[d]),
        .O(rwds_in_ser)
      );
      OSER4#(.HWL("false")) rwds_oser4 (
        .D0(rwds_out),
        .D1(rwds_out),
        .D2(rwds_out),
        .D3(rwds_out),
        .PCLK(system_clk),
        .FCLK(memory_clk),
        .RESET(rst),
        .TX0(rwds_oe_n),
        .TX1(rwds_oe_n),
        .Q0(rwds_out_ser),
        .Q1(rwds_out_ser_oe_n)
      );
      IODELAY #(.C_STATIC_DLY(`READ_DELAY)) iodelay (
        .DI(rwds_in_ser),
        .SETN(1'b0),
        .SDTAP(1'b0),
        .VALUE(1'b0),
        .DO(rwds_in_ser_d),
        .DF(rwds_in_ser_df)
      );
      IDES4 rwds_ides4 (
        .D(rwds_in_ser_d),
        .PCLK(system_clk),
        .FCLK(memory_clk),
        .RESET(rst),
        .CALIB(1'b0),
        .Q0(rwds_in[4*d]),
        .Q1(rwds_in[4*d+1]),
        .Q2(rwds_in[4*d+2]),
        .Q3(rwds_in[4*d+3])
      );

      // DQ: line i of die d carries bit i of each of the die's 4 bytes per
      // system_clk cycle, dq_out/dq_in[32*d + 8*k + i] for k = 0..3 in bus
      // order.
      for (i = 0; i < 8; i++) begin: dq_
        wire dq_out_ser, dq_out_ser_oe_n, dq_in_ser, dq_in_ser_d, dq_in_ser_df;
        IOBUF iobuf (
          .I(dq_out_ser),
          .OEN(dq_out_ser_oe_n),
          .IO(IO_hpram_dq[8*d+i]),
          .O(dq_in_ser)
        );
        OSER4#(.HWL("false")) oser4 (
          .D0(dq_out[32*d+i]),
          .D1(dq_out[32*d+8+i]),
          .D2(dq_out[32*d+16+i]),
          .D3(dq_out[32*d+24+i]),
          .PCLK(system_clk),
          .FCLK(memory_clk),
          .RESET(rst),
          .TX0(dq_oe_n[0]),
          .TX1(dq_oe_n[1]),
          .Q0(dq_out_ser),
          .Q1(dq_out_ser_oe_n)
        );
        IODELAY #(.C_STATIC_DLY(`READ_DELAY)) iodelay (
          .DI(dq_in_ser),
          .SETN(1'b0),
          .SDTAP(1'b0),
          .VALUE(1'b0),
          .DO(dq_in_ser_d),
          .DF(dq_in_ser_df)
        );
        IDES4 ides4 (
          .D(dq_in_ser_d),
          .PCLK(system_clk),
          .FCLK(memory_clk),
          .RESET(rst),
          .CALIB(1'b0),
          .Q0(dq_in[32*d+i]),
          .Q1(dq_in[32*d+8+i]),
          .Q2(dq_in[32*d+16+i]),
          .Q3(dq_in[32*d+24+i])
        );
      end
    end
  endgenerate


endmodule