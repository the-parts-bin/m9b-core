`timescale 1ns / 1ps

// Video/audio path without the CPU: rtl/video_engine.v + rtl/hyperram.sv +
// hr_ram (dpb_8k32_64, Gowin DPB model) + rtl/vram.v + one
// sim/psram_model.v per die. PSRAM and the per-line table are filled
// through backdoors; a short frame (858 x FRAME_H, ACTIVE_H visible
// lines) exercises every mode, and a reference model checks every visible
// pixel, including the output alignment: rgb at cycle t must be the pixel
// at cx(t) - 1. Then audio: two halves refilled by DMA, played back and
// compared sample by sample, with their interrupts.
//
// Run with sim/run_video.sh.
module tb;
  parameter real TCKD = 8.0;
  localparam ACTIVE_W = 720, FRAME_W = 858, ACTIVE_H = 6, FRAME_H = 10;

  GSR GSR (.GSRI(1'b1));

  reg memory_clk = 1'b0;
  reg system_clk = 1'b0;
  always #3.367 memory_clk = ~memory_clk;
  always #6.734 system_clk = ~system_clk;
  wire clk = system_clk;

  reg rst_n = 1'b0;
  reg rst = 1'b1;

  // HDMI-style timing: cx 0..FRAME_W-1, cy 0..FRAME_H-1, cy_next.
  reg [11:0] cx = 0;
  reg [9:0]  cy = 0, cy_next = 1;
  always @(posedge clk) begin
    if (cx == FRAME_W - 1) begin
      cx <= 0;
      cy <= cy_next;
      cy_next <= (cy_next == FRAME_H - 1) ? 10'd0 : cy_next + 1'b1;
    end else begin
      cx <= cx + 1'b1;
    end
  end

  reg        video_enable = 1'b0, audio_enable = 1'b0;
  reg        refill_a = 1'b0, refill_b = 1'b0;
  reg [14:0] block_a = 15'd0, block_b = 15'd0;

  wire [10:0] vram_raddr, hr_raddr;
  wire [31:0] vram_rdata, hr_rdata;
  wire        dma_start, dma_busy;
  wire [15:0] dma_psram_block;
  wire [4:0]  dma_hr_block, dma_count;
  wire [23:0] rgb;
  wire [63:0] audio_pair;
  wire        audio_ready;
  reg         audio_used = 1'b0;
  wire [6:0]  audio_frame_counter;
  wire        irq_vblank, irq_audio_a, irq_audio_b;

  video_engine #(.ACTIVE_W(ACTIVE_W), .FRAME_W(FRAME_W), .ACTIVE_H(ACTIVE_H), .FRAME_H(FRAME_H)) eng (
    .clk(clk), .rst(rst), .hstart(12'd40), .hend(12'd680),
    .cx(cx), .cy(cy), .cy_next(cy_next),
    .video_enable(video_enable), .audio_enable(audio_enable),
    .audio_refill_a(refill_a), .audio_refill_b(refill_b),
    .audio_block_a(block_a), .audio_block_b(block_b),
    .vram_raddr(vram_raddr), .vram_rdata(vram_rdata),
    .hr_raddr(hr_raddr), .hr_rdata(hr_rdata),
    .dma_start(dma_start), .dma_psram_block(dma_psram_block), .dma_hr_block(dma_hr_block),
    .dma_count(dma_count), .dma_busy(dma_busy),
    .rgb(rgb),
    .audio_pair(audio_pair), .audio_ready(audio_ready), .audio_used(audio_used),
    .audio_frame_counter(audio_frame_counter),
    .irq_vblank(irq_vblank), .irq_audio_a(irq_audio_a), .irq_audio_b(irq_audio_b)
  );

  vram vr (
    .wclk(clk), .we(1'b0), .waddr(11'd0), .wdata(32'd0),
    .rclk(clk), .raddr(vram_raddr), .rdata(vram_rdata)
  );

  wire [9:0]  vr_hr_addr;
  wire        vr_hr_read, vr_hr_write, burst_line;
  wire [63:0] hr_read_data, hr_ram_doutb;

  dpb_8k32_64 hr_ram (
    .douta(hr_rdata), .doutb(hr_ram_doutb),
    .clka(clk), .ocea(1'b1), .cea(1'b1), .reseta(rst), .wrea(1'b0),
    .clkb(clk), .oceb(1'b1), .ceb(1'b1), .resetb(rst), .wreb(vr_hr_write & ~burst_line),
    .ada(hr_raddr), .dina(32'd0), .adb(vr_hr_addr), .dinb(hr_read_data)
  );

  wire [1:0]  psram_ck, psram_ck_n, psram_cs_n, psram_reset_n;
  wire [15:0] psram_dq;
  wire [1:0]  psram_rwds;

  hyperram ctrl (
    .system_clk(clk), .memory_clk(memory_clk), .rst_n(rst_n),
    .dma_start(dma_start), .dma_psram_block(dma_psram_block), .dma_hr_block(dma_hr_block),
    .dma_count(dma_count), .dma_busy(dma_busy),
    .line_req_toggle(1'b0), .line_write(1'b0), .line_addr(18'd0), .line_ack_toggle(),
    .burst_line(burst_line),
    .vr_read(vr_hr_read), .vr_write(vr_hr_write), .vr_addr(vr_hr_addr),
    .vr_read_data(hr_ram_doutb), .vr_write_data(hr_read_data),
    .O_hpram_ck(psram_ck), .O_hpram_ck_n(psram_ck_n), .O_hpram_cs_n(psram_cs_n),
    .O_hpram_reset_n(psram_reset_n), .IO_hpram_dq(psram_dq), .IO_hpram_rwds(psram_rwds)
  );

  psram_model #(.TCKD(TCKD)) psram0 (
    .ck(psram_ck[0]), .ck_n(psram_ck_n[0]), .cs_n(psram_cs_n[0]),
    .reset_n(psram_reset_n[0]), .dq(psram_dq[7:0]), .rwds(psram_rwds[0])
  );
  psram_model #(.TCKD(TCKD)) psram1 (
    .ck(psram_ck[1]), .ck_n(psram_ck_n[1]), .cs_n(psram_cs_n[1]),
    .reset_n(psram_reset_n[1]), .dq(psram_dq[15:8]), .rwds(psram_rwds[1])
  );

  // ---------------------------------------------------------------
  // PSRAM content (CPU view): word w = pattern(w); the model backdoor
  // maps it onto the dies as in tb_hyperram.v.
  // ---------------------------------------------------------------
  function [31:0] pattern(input integer w);
    pattern = w * 32'h9E3779B1 + 32'h7F4A7C15;
  endfunction
  function [7:0] psram_byte(input integer a);
    reg [31:0] p;
    begin
      p = pattern(a >> 2);
      psram_byte = p >> (8 * (a & 3));
    end
  endfunction
  // Video RAM backdoor (banks 1 and 2 at words 512..1535, see vram.v).
  function [31:0] vram_word(input integer i);
    vram_word = i < 1024 ? vr.bank1[i - 512] : vr.bank2[i - 1024];
  endfunction

  function [15:0] palette(input integer i);
    reg [31:0] wv;
    begin
      wv = vram_word(512 + i / 2);
      palette = (i & 1) ? wv[31:16] : wv[15:0];
    end
  endfunction
  function [23:0] rgb565(input [15:0] c);
    rgb565 = {c[15:11], c[15:13], c[10:5], c[10:9], c[4:0], c[4:2]};
  endfunction

  // Expected colour of visible pixel (x, y) from its table entry.
  function [23:0] expected(input integer x, input integer y);
    reg [31:0] e;
    integer base, a, c;
    reg [7:0] ch, attr, f;
    begin
      e = vram_word(640 + y);
      base = e[14:0] * 256 + e[21:15] * 2;
      case (e[23:22])
        2'd1: begin
          a = base + 2 * x;
          expected = rgb565({psram_byte(a + 1), psram_byte(a)});
        end
        2'd2: if (!e[28]) expected = rgb565(palette(psram_byte(base + x)));
              else if (x >= 40 && x < 680) expected = rgb565(palette(psram_byte(base + (x - 40) / 2)));
              else expected = 24'd0;
        // 2'd3: reserved (was text mode): black
        default: expected = 24'd0;
      endcase
    end
  endfunction

  integer i, w, errors, checked, frame;
  reg [31:0] p;
  reg checking = 1'b0;
  reg [11:0] px;

  // Pixel checker: rgb at cycle t is pixel (cx(t) - 1, cy(t)).
  always @(posedge clk) if (checking) begin
    if (cx >= 1 && cx <= ACTIVE_W && cy < ACTIVE_H) begin
      px = cx - 1;
      checked = checked + 1;
      if (rgb !== expected(px, cy)) begin
        errors = errors + 1;
        if (errors <= 10)
          $display("  pixel (%0d, %0d) mode %0d: rgb %h, expected %h", px, cy,
                   (vram_word(640 + cy) >> 22) & 3, rgb, expected(px, cy));
      end
    end else if (rgb !== 24'd0 && !(cx == 0 && cy == 0)) begin
      // Everything outside the visible area must be black (cx == 0 shows
      // the previous line's last cycle, blanking).
      errors = errors + 1;
      if (errors <= 10) $display("  non-black %h outside the picture at cx %0d cy %0d", rgb, cx, cy);
    end
  end

  // Audio: collect played samples.
  integer npairs = 0, aerr = 0, irqa = 0, irqb = 0, nvbl = 0;
  reg [63:0] want_pair;
  always @(posedge clk) begin
    if (irq_audio_a) irqa = irqa + 1;
    if (irq_audio_b) irqb = irqb + 1;
    if (irq_vblank) nvbl = nvbl + 1;
    audio_used <= audio_ready && !audio_used;   // hdmi consumes each packet
    if (audio_ready && !audio_used && audio_enable && npairs < 300) begin
      // Pair k plays samples 2k and 2k+1 of the sequence (see
      // audio_word).
      want_pair = {audio_word(2 * npairs + 1), audio_word(2 * npairs)};
      if (npairs >= 1 && audio_pair !== want_pair) begin
        aerr = aerr + 1;
        if (aerr <= 5) $display("  audio pair %0d: %h, expected %h", npairs, audio_pair, want_pair);
      end
      npairs = npairs + 1;
    end
  end
  function [31:0] audio_word(input integer s);
    // Samples 0..255 from PSRAM block 200..203 (half A), 256..511 from
    // 210..213 (half B), then half A again (not refilled here).
    audio_word = pattern(((s % 512) < 256 ? 200 * 64 : 210 * 64 - 256) + (s % 512));
  endfunction

  initial begin
    // Backdoor: PSRAM (first 64 KB of the interleaved space).
    #1;
    for (w = 0; w < 65536 / 4 * 4; w = w + 1) begin
      p = pattern(w);
      if (w & 1) begin
        psram1.mem[(w >> 1) * 2]     = {p[7:0], p[15:8]};
        psram1.mem[(w >> 1) * 2 + 1] = {p[23:16], p[31:24]};
      end else begin
        psram0.mem[(w >> 1) * 2]     = {p[7:0], p[15:8]};
        psram0.mem[(w >> 1) * 2 + 1] = {p[23:16], p[31:24]};
      end
    end
    // Backdoor: per-line table.
    //   line 0: 16 bpp, block 0            line 3: mode 3 (reserved, black; was text)
    //   line 1: 16 bpp, block 20, offset 5 line 4: blank
    //   line 2: 8 bpp, block 40, offset 3  line 5: 16 bpp, block 80, offset 127
    //   (line 4 was blank: now 8 bpp 2x, block 100, offset 5, window 40..679)
    vr.bank1[128 + 0] = {4'd0, 4'd0, 2'd1, 7'd0,   15'd0};
    vr.bank1[128 + 1] = {4'd0, 4'd0, 2'd1, 7'd5,   15'd20};
    vr.bank1[128 + 2] = {4'd0, 4'd0, 2'd2, 7'd3,   15'd40};
    vr.bank1[128 + 3] = {4'd0, 4'd5, 2'd3, 7'd1,   15'd60};
    vr.bank1[128 + 4] = {3'd0, 1'b1, 4'd0, 2'd2, 7'd5, 15'd100};
    vr.bank1[128 + 5] = {4'd0, 4'd0, 2'd1, 7'd127, 15'd80};

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);
    rst = 1'b0;
    // Controller waits ~16384 cycles before CR0; then enable video.
    repeat (17000) @(posedge clk);
    video_enable = 1'b1;

    // Skip the rest of this frame and one whole frame (lines are fetched
    // two ahead, so the first frame after enabling can miss its first
    // lines), then check.
    wait (cy == 0 && cx == 0); @(posedge clk);
    wait (cy == 0 && cx == 0); @(posedge clk);
    wait (cy == 0 && cx == 0);
    errors = 0; checked = 0;
    checking = 1'b1;
    for (frame = 0; frame < 2; frame = frame + 1) begin
      @(posedge clk);
      wait (cy == 0 && cx == 0);
    end
    checking = 1'b0;
    $display("video: %s, %0d pixels checked, %0d errors, %0d vblank irqs", errors ? "FAIL" : "PASS",
             checked, errors, nvbl);

    // Audio: refill both halves, then play.
    @(posedge clk); block_a <= 15'd200; refill_a <= 1'b1;
    @(posedge clk); refill_a <= 1'b0;
    @(posedge clk); block_b <= 15'd210; refill_b <= 1'b1;
    @(posedge clk); refill_b <= 1'b0;
    repeat (3000) @(posedge clk);
    audio_enable = 1'b1;
    wait (npairs == 300);
    $display("audio: %s, 300 pairs, %0d wrong, irq a %0d, irq b %0d", aerr ? "FAIL" : "PASS", aerr, irqa, irqb);
    $finish;
  end

  initial begin
    #30000000;
    $display("TIMEOUT");
    $finish;
  end
endmodule
