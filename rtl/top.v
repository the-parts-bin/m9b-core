// VexiiRiscv SoC for the Tang Nano 9K: clocks, resets and the video/audio
// side here; CPU, memories and the PSRAM path in soc.v.
//
// 720x480 59.94 Hz: pll_hdmi makes the 135 MHz TMDS bit clock from the
// 27 MHz oscillator, and a CLKDIV /5 of it the 27 MHz pixel clock, which
// also runs the CPU. pll_main makes the PSRAM clocks, 144 MHz and 72 MHz
// for the controller, and 48 MHz, divided by 4 to the USB core's 12 MHz.

`include "soc.v"

module top (
  input  wire       ext_clk,  // 27 MHz onboard oscillator
  input  wire       reset,    // reset button, active low (pressed = 0)
  input  wire       rxd,      // UART RX (from USB-serial chip)
  output wire       txd,      // UART TX (to USB-serial chip)
  input  wire       rxd2,     // second UART port (header J5: an external
  output wire       txd2,     //   3.3 V USB-serial adapter)
  output wire [5:0] led,      // onboard LEDs, active low

  // SPI flash (on-board P25Q32U, 4 MB)
  output wire       flash_clk,
  output wire       flash_cs_n,
  output wire       flash_mosi,
  input  wire       flash_miso,

  // SD card (SPI mode)
  output wire       sd_clk,
  output wire       sd_cs_n,
  output wire       sd_mosi,
  input  wire       sd_miso,

  // USB (low speed, keyboard/mouse/gamepad): D- / D+ with 15k pull-downs
  inout  wire       usb_dm,
  inout  wire       usb_dp,
  inout  wire       usb2_dm,  // second port
  inout  wire       usb2_dp,

  // HDMI output
  output            tmds_clk_p,
  output            tmds_clk_n,
  output     [2:0]  tmds_data_p,  // r,g,b
  output     [2:0]  tmds_data_n,

  // PSRAM (two dies)
  output logic [1:0]  O_psram_ck,
  output logic [1:0]  O_psram_ck_n,
  inout  wire  [1:0]  IO_psram_rwds,
  inout  wire  [15:0] IO_psram_dq,
  output logic [1:0]  O_psram_reset_n,
  output logic [1:0]  O_psram_cs_n  
);

  // -------------------------------------------------------------------
  // Clock / reset
  // -------------------------------------------------------------------

  wire memory_clk;      // 144 MHz  (PSRAM, DDR)
  wire system_clk;      // 72 MHz   (PSRAM controller)
  wire usb_clk_48;      // 48 MHz   (pll_main clkoutd3)
  wire usb_clk;         // 12 MHz   (USB HID host core)
  wire hdmi_bit_clk;    // 135 MHz  (TMDS, DDR 10:1)
  wire pixel_clk;       // 27 MHz   (hdmi_bit_clk / 5: video, audio)
  wire cpu_clk;         // 36 MHz   (system_clk / 2: CPU, I/O)
  wire hdmi_pixel_clk = pixel_clk;

  // clkin: 27 MHz; clkout: 144 MHz; clkoutd: 72 MHz; clkoutd3: 48 MHz
  pll_main pll_main_instance(
    .clkout(memory_clk),
    .clkoutd(system_clk),
    .clkoutd3(usb_clk_48),
    .clkin(ext_clk)
  );

  // The USB core needs exactly 12 MHz (8 clocks per low-speed bit).
  CLKDIV #(.DIV_MODE("4"), .GSREN("false")) usb_div (
    .HCLKIN(usb_clk_48),
    .RESETN(1'b1),
    .CALIB(1'b0),
    .CLKOUT(usb_clk)
  );

  // The CPU runs at system_clk / 2, from the same clock tree as the PSRAM
  // controller, so the bridge between them is synchronous (timed as one
  // design, no synchronizers). Everything the CPU exchanges with the
  // pixel clock goes through the synchronizers in soc.v.
  CLKDIV #(.DIV_MODE("2"), .GSREN("false")) cpu_div (
    .HCLKIN(system_clk),
    .RESETN(1'b1),
    .CALIB(1'b0),
    .CLKOUT(cpu_clk)
  );

  // clkin: 27 MHz; clkout: 135 MHz
  pll_hdmi pll_hdmi_instance(
    .clkout(hdmi_bit_clk),
    .clkin(ext_clk)
  );

  // The serializers' parallel clock has to be phase-aligned with their
  // serial clock, so the pixel clock is the serial clock divided down.
  CLKDIV #(.DIV_MODE("5"), .GSREN("false")) pixel_div (
    .HCLKIN(hdmi_bit_clk),
    .RESETN(1'b1),
    .CALIB(1'b0),
    .CLKOUT(pixel_clk)
  );

  // Stretch reset for a few thousand cycles after power-up / button
  // release: some BRAM implementations return garbage for the first
  // few microseconds, and this also debounces the reset button.
  // The UART's receiver resets the whole system, like the button, when it
  // sees "\x1bM9BRESET" (see uart.v), whatever the CPU is doing: tools/run.py
  // uses it before each upload.
  wire uart_reset;

  // One UART, two ports: TX goes out on both, RX is the AND of both (idle
  // high; pulled up when nothing is connected), so either host can use the
  // console, the loader and the reset string, one at a time.
  wire uart_tx;
  wire uart_rx = rxd & rxd2;
  assign txd  = uart_tx;
  assign txd2 = uart_tx;

  // The reset counter runs on the CPU clock, whose domain the UART's reset
  // request comes from; the pixel domain's reset is synchronized from it.
  reg [15:0] reset_cnt = 0;
  wire rst_n = &reset_cnt;
  always @(posedge cpu_clk or negedge reset) begin
    if (!reset)
      reset_cnt <= 0;
    else if (uart_reset)
      reset_cnt <= 0;
    else if (!rst_n)
      reset_cnt <= reset_cnt + 1'b1;
  end

  // Active-high reset for the video/audio logic and the serializers.
  reg rst_pix_s = 1'b1, rst_pix = 1'b1;
  always @(posedge pixel_clk) begin
    rst_pix_s <= ~rst_n;
    rst_pix <= rst_pix_s;
  end

  // -------------------------------------------------------------------
  // Audio and image generation
  // -------------------------------------------------------------------
  wire[11:0] x_cnt;
  wire[9:0] y_cnt;
  wire[9:0] y_cnt_next;
  wire [23:0]color;

  // Free-running video-timing counters, exposed read-only to the CPU (see
  // soc.v; CLOCK_CNT itself is counted in soc.v, on the CPU clock). frame_cnt
  // increments once per frame (detected at the first pixel of a frame,
  // x_cnt==0 && y_cnt==0, which -- since x_cnt increments every cycle
  // with no stalls -- is true for exactly one pixel clock cycle per
  // frame).
  reg [31:0] frame_cnt;

  always @(posedge hdmi_pixel_clk) begin
    if (rst_pix) begin
      frame_cnt <= 32'd0;
    end else begin
      if (x_cnt == 12'd0 && y_cnt == 10'd0) begin
        frame_cnt <= frame_cnt + 1'b1;
      end
    end
  end

  // Picture and sound come from the video/audio engine in soc.v, or, with
  // HDMI_TEST_PATTERN defined, from the old test pattern (gpu.sv) and a
  // 440 Hz sawtooth, to check the HDMI side on its own.
  reg [15:0] audio_sample_data[1:0] [1:0];
  wire [23:0] soc_rgb;
  wire [63:0] soc_audio_pair;
  wire [6:0]  soc_audio_frame_counter;
  wire        soc_audio_ready;
  wire [23:0] rgb;
  logic [2:0] tmds;
  logic       tmds_clock;
  reg  [6:0]  audio_frame_counter;
  reg         audio_sample_ready;
  wire        audio_sample_used;

`ifdef HDMI_TEST_PATTERN
  gpu gpu_instance(
    .rst(rst_pix),
    .system_clk(hdmi_pixel_clk),
    .cx(x_cnt),
    .cy(y_cnt),
    .rgb(rgb)
  );

  // One packet of 2 samples every 1125 pixel clocks (48 kHz audio).
  reg [10:0] tp_audio_acc;
  reg [15:0] tp_sample;
  wire tp_audio_tick = tp_audio_acc == 11'd1124;
  always @(posedge hdmi_pixel_clk) begin
    if (rst_pix) begin
      tp_audio_acc <= 11'd0;
      tp_sample <= 16'd0;
      audio_sample_ready <= 1'b0;
      audio_frame_counter <= 7'd0;
    end else begin
      tp_audio_acc <= tp_audio_tick ? 11'd0 : tp_audio_acc + 11'd1;
      if (tp_audio_tick) begin
        tp_sample <= tp_sample + 16'd1200;   // ~440 Hz sawtooth
        audio_sample_ready <= 1'b1;
        audio_frame_counter <= (audio_frame_counter == 7'd95) ? 7'd0 : audio_frame_counter + 1'b1;
      end else if (audio_sample_used) begin
        audio_sample_ready <= 1'b0;
      end
    end
  end
  always @(*) begin
    audio_sample_data[0][0] = tp_sample;
    audio_sample_data[0][1] = tp_sample;
    audio_sample_data[1][0] = tp_sample;
    audio_sample_data[1][1] = tp_sample;
  end
  wire soc_audio_used = 1'b0;
`else
  assign rgb = soc_rgb;
  always @(*) begin
    audio_sample_ready  = soc_audio_ready;
    audio_frame_counter = soc_audio_frame_counter;
    audio_sample_data[0][0] = soc_audio_pair[15:0];
    audio_sample_data[0][1] = soc_audio_pair[31:16];
    audio_sample_data[1][0] = soc_audio_pair[47:32];
    audio_sample_data[1][1] = soc_audio_pair[63:48];
  end
  wire soc_audio_used = audio_sample_used;
`endif

  hdmi hdmi_instance(
    .clk_pixel_x5(hdmi_bit_clk),
    .clk_pixel(hdmi_pixel_clk),
    .reset(rst_pix),
    .serializer_reset(rst_pix),
    .rgb(rgb),
    .audio_sample_data(audio_sample_data),
    .audio_sample_ready(audio_sample_ready),
    .audio_sample_used(audio_sample_used),
    .audio_frame_counter(audio_frame_counter),
    .tmds(tmds),
    .tmds_clock(tmds_clock),
    .cx(x_cnt),
    .cy(y_cnt),
    .cy_next(y_cnt_next)
  );

  // Output driver section.
  ELVDS_OBUF tmds_r (.I(tmds[2]), .O(tmds_data_p[2]), .OB(tmds_data_n[2]));
  ELVDS_OBUF tmds_g (.I(tmds[1]), .O(tmds_data_p[1]), .OB(tmds_data_n[1]));
  ELVDS_OBUF tmds_b (.I(tmds[0]), .O(tmds_data_p[0]), .OB(tmds_data_n[0]));
  ELVDS_OBUF tmds_clk (.I(tmds_clock), .O(tmds_clk_p), .OB(tmds_clk_n));

  // -------------------------------------------------------------------
  // CPU, memories, PSRAM
  // -------------------------------------------------------------------
  soc soc_instance (
    .cpu_clk(cpu_clk),
    .rst_n(rst_n),
    .pixel_clk(pixel_clk),
    .pix_rst(rst_pix),
    .system_clk(system_clk),
    .memory_clk(memory_clk),
    .rxd(uart_rx),
    .txd(uart_tx),
    .uart_reset(uart_reset),
    .x_cnt(x_cnt),
    .y_cnt(y_cnt),
    .y_cnt_next(y_cnt_next),
    .frame_cnt(frame_cnt),
    .rgb(soc_rgb),
    .audio_pair(soc_audio_pair),
    .audio_ready(soc_audio_ready),
    .audio_used(soc_audio_used),
    .audio_frame_counter(soc_audio_frame_counter),
    .flash_clk(flash_clk),
    .flash_cs_n(flash_cs_n),
    .flash_mosi(flash_mosi),
    .flash_miso(flash_miso),
    .sd_clk(sd_clk),
    .sd_cs_n(sd_cs_n),
    .sd_mosi(sd_mosi),
    .sd_miso(sd_miso),
    .usb_clk(usb_clk),
    .usb_dm(usb_dm),
    .usb_dp(usb_dp),
    .usb2_dm(usb2_dm),
    .usb2_dp(usb2_dp),
    .O_psram_ck(O_psram_ck),
    .O_psram_ck_n(O_psram_ck_n),
    .IO_psram_rwds(IO_psram_rwds),
    .IO_psram_dq(IO_psram_dq),
    .O_psram_reset_n(O_psram_reset_n),
    .O_psram_cs_n(O_psram_cs_n)
  );

  // -------------------------------------------------------------------
  // Heartbeat LED: purely cosmetic, confirms the design is alive even
  // without a terminal attached. LEDs on the Tang Nano 9K are active low.
  // -------------------------------------------------------------------
  reg [23:0] blink_cnt = 0;
  always @(posedge ext_clk) blink_cnt <= blink_cnt + 1'b1;
  assign led = {5'b11111, ~blink_cnt[23]};



endmodule
