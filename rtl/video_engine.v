// Scanout and audio, on the pixel clock (27 MHz, 720x480 59.94 Hz).
//
// Video: every visible line comes from a 32-bit entry in the per-line table
// in video RAM (vram.v, word TABLE_WORD + line):
//   [14:0]  PSRAM source, in 256-byte blocks (interleaved byte address >> 8)
//   [21:15] scroll offset, in 2-byte units (one pixel at 16 bpp) into the
//           first block
//   [23:22] mode: 0 blank, 1 16 bpp RGB565, 2 8 bpp palette, 3 reserved
//           (blank; was text mode, removed to free logic and the font's
//           block RAM: text is drawn in software now)
//   [27:24] reserved
//   [28]    8 bpp: 2x horizontally -- each source byte makes two pixels,
//           starting at column hstart; columns outside [hstart, hend) are
//           black (e.g. 320 pixels doubled into columns 40..679)
//   [31:29] reserved
// At the start of line L's front porch (cx == FETCH_X) the entry for line
// L + 2 is read and its data DMA'd from PSRAM into line buffer (L + 2) & 1
// in hr_ram (7 blocks each: 6 for a 16 bpp line, plus one when the
// scroll offset makes it straddle a block). A line is 720 x 16 bpp or 720
// x 8 bpp (palette index per byte).
//
// Audio: 48 kHz stereo 16-bit, one 32-bit word per sample (left in bits
// 15:0). Two 1 KB halves in hr_ram (256 samples, 5.3 ms each) play
// alternately; when playback moves on from a half, irq_audio_a/b fires
// and the CPU refills that half by writing its pointer (audio_refill_a/b
// with the new PSRAM block), which DMAs 4 blocks into it.
//
// hr_ram port A (32-bit, registered read) is only read here: by whichever
// pixel path the line's mode uses, and by audio in the gap after the table
// fetch (AUDIO_X0..AUDIO_X1), where no pixel path is reading.
//
// Output timing: rgb at cycle t is the pixel at cx(t) - 1 (what hdmi.sv
// expects, as its video_data is registered from rgb alongside its own
// cx-derived periods). Each mode's path looks ahead of cx by its pipeline
// depth: 16 bpp by 1 (line buffer read), 8 bpp by 2 (line buffer, then
// palette).
module video_engine #(
  parameter ACTIVE_W = 720,
  parameter FRAME_W  = 858,
  parameter ACTIVE_H = 480,
  parameter FRAME_H  = 525,
  parameter FETCH_X  = 736,
  parameter AUDIO_X0 = 744,
  parameter AUDIO_X1 = 840
) (
  input  wire        clk,
  input  wire        rst,

  input  wire [11:0] cx,
  input  wire [9:0]  cy,
  input  wire [9:0]  cy_next,

  // Configuration (already synchronized to clk).
  input  wire        video_enable,
  input  wire        audio_enable,
  input  wire [11:0] hstart,             // window for 2x lines (see above)
  input  wire [11:0] hend,
  input  wire        audio_refill_a,     // one-cycle pulses
  input  wire        audio_refill_b,
  input  wire [14:0] audio_block_a,      // stable around the pulses
  input  wire [14:0] audio_block_b,

  // Video RAM read port (registered read).
  output reg  [10:0] vram_raddr,
  input  wire [31:0] vram_rdata,

  // hr_ram port A (registered read).
  output reg  [10:0] hr_raddr,
  input  wire [31:0] hr_rdata,

  // PSRAM controller DMA port (see hyperram.sv).
  output reg         dma_start,
  output reg  [15:0] dma_psram_block,
  output reg  [4:0]  dma_hr_block,
  output reg  [4:0]  dma_count,
  input  wire        dma_busy,

  output reg  [23:0] rgb,

  // HDMI audio: one packet of 2 stereo samples per audio_ready (24 kHz).
  output reg  [63:0] audio_pair,        // {s1 R, s1 L, s0 R, s0 L}
  output reg         audio_ready,
  input  wire        audio_used,
  output reg  [6:0]  audio_frame_counter,

  // One-cycle interrupt pulses.
  output reg         irq_vblank,
  output reg         irq_audio_a,
  output reg         irq_audio_b
);

  localparam [10:0] PAL_WORD     = 11'd512;
  localparam [10:0] TABLE_WORD   = 11'd640;
  localparam [10:0] BUF_WORDS    = 11'd448;    // 7 blocks of 64 words
  localparam [10:0] AUDIO_A_WORD = 11'd1536;   // hr_ram blocks 24..27
  localparam [10:0] AUDIO_B_WORD = 11'd1792;   // hr_ram blocks 28..31

  localparam [1:0] MODE_BLANK = 2'd0, MODE_16 = 2'd1, MODE_8 = 2'd2;

  function [23:0] rgb565;
    input [15:0] c;
    rgb565 = {c[15:11], c[15:13], c[10:5], c[10:9], c[4:0], c[4:2]};
  endfunction

  function [7:0] byte_lane;
    input [31:0] w;
    input [1:0]  lane;
    byte_lane = w >> {lane, 3'b000};
  endfunction

  // -------------------------------------------------------------------
  // Per-line entries: slot line & 1 holds the entry of the line whose data
  // is (being) fetched into line buffer line & 1.
  // -------------------------------------------------------------------
  reg [31:0] entry0, entry1;

  // -------------------------------------------------------------------
  // Look-ahead positions for the two pixel paths, wrapping onto the next
  // line through cy_next. Two register stages, so that hr_ram's address
  // comes straight from a flop: stage 0 computes, from cx, the position
  // each path works on two cycles later; stage 1 turns those into the
  // flags, offsets and hr_ram address of the current cycle (act16, byte16,
  // ... below are all "this cycle's" values, as if computed from cx + lead).
  // -------------------------------------------------------------------
  localparam [11:0] FRAME_W12 = FRAME_W;

  // Stage 0: positions two cycles ahead (leads 1 and 2, plus 2).
  wire [11:0] q1 = cx + 12'd3;
  wire [11:0] q2 = cx + 12'd4;
  // Wrap flags, q >= FRAME_W, i.e. cx >= FRAME_W - lead: registered one
  // cycle early (cx(t) >= K  <=>  cx(t-1) >= K - 1, unless cx(t-1) was the
  // last position of the line).
  reg         w1, w2;
  always @(posedge clk) begin
    w1 <= cx >= FRAME_W12 - 12'd4  && cx != FRAME_W12 - 12'd1;
    w2 <= cx >= FRAME_W12 - 12'd5  && cx != FRAME_W12 - 12'd1;
  end
  wire [11:0] n1x = w1 ? q1 - FRAME_W12 : q1;
  wire [11:0] n2x = w2 ? q2 - FRAME_W12 : q2;
  wire [9:0]  n1y = w1 ? cy_next : cy;
  wire [9:0]  n2y = w2 ? cy_next : cy;
  reg  [11:0] s_xa1, s_xa2;
  reg  [11:0] s_xd2;      // 8 bpp path: column - hstart (2x lines)
  reg         s_in2;      // 8 bpp path: column in [hstart, hend)
  reg  [9:0]  s_ya1, s_ya2;
  reg  [31:0] s_e1, s_e2;
  always @(posedge clk) begin
    s_xa1 <= n1x;  s_ya1 <= n1y;
    s_xa2 <= n2x;  s_ya2 <= n2y;
    s_xd2 <= n2x - hstart;
    s_in2 <= n2x >= hstart && n2x < hend;
    s_e1 <= n1y[0] ? entry1 : entry0;
    s_e2 <= n2y[0] ? entry1 : entry0;
  end

  // Stage 1: flags and line buffer offsets (combinational from stage 0).
  wire        n_act16 = video_enable && s_xa1 < ACTIVE_W && s_ya1 < ACTIVE_H && s_e1[23:22] == MODE_16;
  wire        dbl8    = s_e2[28];
  wire        n_act8  = video_enable && s_xa2 < ACTIVE_W && s_ya2 < ACTIVE_H && s_e2[23:22] == MODE_8 &&
                        (!dbl8 || s_in2);
  wire [11:0] n_byte16 = {3'b000, s_e1[21:15], 1'b0} + {s_xa1[10:0], 1'b0};
  wire [11:0] n_byte8  = {3'b000, s_e2[21:15], 1'b0} + (dbl8 ? {1'b0, s_xd2[11:1]} : {1'b0, s_xa2[10:0]});
  wire [10:0] n_base1  = s_ya1[0] ? BUF_WORDS : 11'd0;
  wire [10:0] n_base2  = s_ya2[0] ? BUF_WORDS : 11'd0;

  // -------------------------------------------------------------------
  // Audio fetch state (declared here for the hr_ram address).
  // -------------------------------------------------------------------
  reg        aud_half;      // half being fetched from
  reg [7:0]  aud_idx;       // next sample to fetch within the half
  reg [1:0]  aud_rd;        // 0 idle, 1/2 reading the two words, 3 done
  wire [10:0] aud_word = (aud_half ? AUDIO_B_WORD : AUDIO_A_WORD) + {3'b000, aud_idx};

  // This cycle's values (registered at the end of stage 1).
  reg         act16, act8;
  reg  [11:0] byte16, byte8;

  // hr_ram address, registered: whichever path is active next cycle (they
  // never overlap: a line has one mode, and audio only reads after the
  // table fetch). Audio reads its two words while aud_rd is 1 and 2.
  always @(posedge clk) begin
    act16  <= n_act16;
    act8   <= n_act8;
    byte16 <= n_byte16;
    byte8  <= n_byte8;
    if (n_act16)
      hr_raddr <= n_base1 + {1'b0, n_byte16[11:2]};
    else if (n_act8)
      hr_raddr <= n_base2 + {1'b0, n_byte8[11:2]};
    else if (aud_rd == 2'd1)
      hr_raddr <= aud_word + 11'd1;
    else
      hr_raddr <= aud_word;
  end

  // -------------------------------------------------------------------
  // 16 bpp path: cycle 0 line buffer address, cycle 1 colour.
  // -------------------------------------------------------------------
  reg        a16_1, half16_1;
  always @(posedge clk) begin
    a16_1    <= act16;
    half16_1 <= byte16[1];
  end
  wire [23:0] c16 = a16_1 ? rgb565(half16_1 ? hr_rdata[31:16] : hr_rdata[15:0]) : 24'd0;

  // -------------------------------------------------------------------
  // 8 bpp path: cycle 0 line buffer address, cycle 1 palette address,
  // cycle 2 colour.
  // -------------------------------------------------------------------
  reg        a8_1, a8_2, half8_2;
  reg [1:0]  lane8_1;
  wire [7:0] idx8 = byte_lane(hr_rdata, lane8_1);
  always @(posedge clk) begin
    a8_1    <= act8;
    lane8_1 <= byte8[1:0];
    a8_2    <= a8_1;
    half8_2 <= idx8[0];
  end
  wire [23:0] c8 = a8_2 ? rgb565(half8_2 ? vram_rdata[31:16] : vram_rdata[15:0]) : 24'd0;

  // Line whose entry is read at this line's FETCH_X: two lines ahead.
  wire [10:0] l2 = {1'b0, cy} + 11'd2;
  wire [9:0]  fetch_line = (l2 >= FRAME_H) ? l2 - FRAME_H : l2[9:0];

  // -------------------------------------------------------------------
  // Video RAM address: table fetch, 8 bpp palette.
  // -------------------------------------------------------------------
  reg        fetch_now;   // cx == FETCH_X, registered
  reg [10:0] table_addr;  // TABLE_WORD + fetch_line, registered
  always @(posedge clk) begin
    fetch_now <= cx == FETCH_X - 1;
    table_addr <= TABLE_WORD + {1'b0, fetch_line};
  end
  always @(*) begin
    if (fetch_now)
      vram_raddr = table_addr;
    else if (a8_1)
      vram_raddr = PAL_WORD + {4'b0000, idx8[7:1]};
    else
      vram_raddr = table_addr;
  end

  // Output: at most one path is non-black at any time.
  always @(posedge clk) rgb <= c16 | c8;

  // -------------------------------------------------------------------
  // Line fetch: at cx == FETCH_X of line L, read the entry of line L + 2;
  // one cycle later store it and queue its DMA.
  // -------------------------------------------------------------------
  reg         fetch_d;
  reg  [9:0]  fetch_line_d;

  reg         vid_pending;
  reg  [15:0] vid_block;
  reg  [4:0]  vid_hr_block, vid_count;

  reg         aud_pending_a, aud_pending_b;
  reg  [14:0] aud_block_a_r, aud_block_b_r;

  // The entry is read at FETCH_X, registered as fe the cycle after
  // (fetch_d), and turned into a DMA request the cycle after that
  // (fetch_d2).
  reg  [31:0] fe;
  reg         fetch_d2;
  reg  [9:0]  fetch_line_d2;
  // 1440 or 720 bytes, plus up to 254 bytes of scroll offset.
  wire [4:0]  fe_blocks = (fe[23:22] == MODE_16 ? 5'd6 : 5'd3) +
                          (fe[21:15] != 7'd0 ? 5'd1 : 5'd0);

  reg dma_issued;

  always @(posedge clk) begin
    if (rst) begin
      entry0 <= 32'd0;
      entry1 <= 32'd0;
      fetch_d <= 1'b0;
      fetch_d2 <= 1'b0;
      vid_pending <= 1'b0;
      aud_pending_a <= 1'b0;
      aud_pending_b <= 1'b0;
      dma_start <= 1'b0;
      dma_issued <= 1'b0;
    end else begin
      fetch_d <= fetch_now && video_enable && fetch_line < ACTIVE_H;
      fetch_line_d <= fetch_line;
      fe <= vram_rdata;
      fetch_d2 <= fetch_d;
      fetch_line_d2 <= fetch_line_d;
      if (fetch_d2) begin
        if (fetch_line_d2[0]) entry1 <= fe; else entry0 <= fe;
        if (fe[23:22] == MODE_16 || fe[23:22] == MODE_8) begin
          vid_pending <= 1'b1;   // replaces a fetch that didn't get started
          vid_block <= {1'b0, fe[14:0]};
          vid_hr_block <= fetch_line_d2[0] ? 5'd7 : 5'd0;
          vid_count <= fe_blocks;
        end
      end

      if (audio_refill_a) begin
        aud_pending_a <= 1'b1;
        aud_block_a_r <= audio_block_a;
      end
      if (audio_refill_b) begin
        aud_pending_b <= 1'b1;
        aud_block_b_r <= audio_block_b;
      end

      // DMA arbiter: video first (deadline: two lines), then audio. After
      // a start, wait for the controller to report busy before looking
      // at dma_busy again.
      dma_start <= 1'b0;
      if (dma_issued) begin
        if (dma_busy) dma_issued <= 1'b0;
      end else if (!dma_busy && !dma_start) begin
        if (vid_pending && !fetch_d2) begin
          dma_start <= 1'b1;
          dma_issued <= 1'b1;
          dma_psram_block <= vid_block;
          dma_hr_block <= vid_hr_block;
          dma_count <= vid_count;
          vid_pending <= 1'b0;
        end else if (aud_pending_a && !audio_refill_a) begin
          dma_start <= 1'b1;
          dma_issued <= 1'b1;
          dma_psram_block <= {1'b0, aud_block_a_r};
          dma_hr_block <= 5'd24;
          dma_count <= 5'd4;
          aud_pending_a <= 1'b0;
        end else if (aud_pending_b && !audio_refill_b) begin
          dma_start <= 1'b1;
          dma_issued <= 1'b1;
          dma_psram_block <= {1'b0, aud_block_b_r};
          dma_hr_block <= 5'd28;
          dma_count <= 5'd4;
          aud_pending_b <= 1'b0;
        end
      end
    end
  end

  // -------------------------------------------------------------------
  // Audio: a packet of 2 samples every 1125 cycles (24 kHz). The next
  // pair is fetched from hr_ram in the audio window (at most one line
  // away, 858 cycles).
  // -------------------------------------------------------------------
  reg [10:0] aud_acc;
  wire aud_tick = aud_acc == 11'd1124;
  reg        need_pair, pair_valid;
  reg [63:0] next_pair;
  wire in_window = cx >= AUDIO_X0 && cx < AUDIO_X1;

  always @(posedge clk) begin
    irq_vblank <= cx == 12'd0 && cy == ACTIVE_H;
    irq_audio_a <= 1'b0;
    irq_audio_b <= 1'b0;
    if (rst) begin
      aud_acc <= 11'd0;
      audio_ready <= 1'b0;
      audio_pair <= 64'd0;
      audio_frame_counter <= 7'd0;
      aud_half <= 1'b0;
      aud_idx <= 8'd0;
      aud_rd <= 2'd0;
      need_pair <= 1'b0;
      pair_valid <= 1'b0;
    end else begin
      aud_acc <= aud_tick ? 11'd0 : aud_acc + 11'd1;

      if (aud_tick) begin
        audio_pair <= (audio_enable && pair_valid) ? next_pair : 64'd0;
        pair_valid <= 1'b0;
        audio_ready <= 1'b1;
        audio_frame_counter <= (audio_frame_counter == 7'd95) ? 7'd0 : audio_frame_counter + 1'b1;
      end else if (audio_used) begin
        audio_ready <= 1'b0;
      end

      if (!audio_enable) begin
        aud_half <= 1'b0;
        aud_idx <= 8'd0;
        aud_rd <= 2'd0;
        need_pair <= 1'b1;
      end else begin
        if (aud_tick) need_pair <= 1'b1;
        case (aud_rd)
          2'd0: if (need_pair && !pair_valid && in_window && cx < AUDIO_X1 - 4) aud_rd <= 2'd1;
          2'd1: aud_rd <= 2'd2;                                  // sample aud_idx addressed
          2'd2: begin next_pair[31:0] <= hr_rdata; aud_rd <= 2'd3; end
          2'd3: begin
            next_pair[63:32] <= hr_rdata;
            pair_valid <= 1'b1;
            need_pair <= 1'b0;
            aud_rd <= 2'd0;
            aud_idx <= aud_idx + 8'd2;
            if (aud_idx == 8'd254) begin
              // Moving on from this half: the CPU can refill it.
              aud_half <= ~aud_half;
              if (aud_half) irq_audio_b <= 1'b1;
              else          irq_audio_a <= 1'b1;
            end
          end
        endcase
      end
    end
  end

endmodule
