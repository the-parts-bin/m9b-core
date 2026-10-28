`timescale 1ns / 1ps
// SD card model in SPI mode for tb_soc.v: enough for firmware/sd.c.
//   CMD0, CMD8 (v2, echo), CMD55 + ACMD41 (ready on the 3rd try), CMD58
//   (OCR: SDHC), CMD9 (CSD v2, 1 GB), CMD6 (switch to High Speed), CMD17,
//   CMD18 (streams sectors until CMD12, which can come at any byte), CMD12.
// Sector s, byte i holds sd_byte(s, i); data comes after a few bytes of
// access latency. Timing, as a real card's limits:
//   - MISO changes after each falling SCLK edge, or after each rising one
//     once switched to High Speed (CMD6), as a real card does: it is
//     undefined (x) from TOH after the edge until TODLY after it, then the
//     next bit. A host that samples outside that window reads x (and the
//     data check fails).
//   - MOSI must be stable TISU before each rising edge (counted in
//     setup_errors).
module sd_card_model #(
  parameter real TODLY = 14.0,   // output delay, max (SD: 14 ns)
  parameter real TOH   = 2.5,    // output hold, min
  parameter real TISU  = 5.0     // input setup, min (High Speed: 6)
) (
  input  wire sclk,
  input  wire cs_n,
  input  wire mosi,
  output reg  miso
);
  function [7:0] sd_byte(input [31:0] s, input [9:0] i);
    sd_byte = s[7:0] ^ (s[15:8] << 1) ^ i[7:0] ^ {7'd0, i[8]} ^ 8'h3C;
  endfunction

  // Bytes to send (MSB first), a ring; 0xFF when empty.
  reg [7:0] q [0:2047];
  integer qh = 0, qt = 0;
  task put(input [7:0] b); begin q[qt] = b; qt = (qt + 1) % 2048; end endtask
  function integer qlen(input dummy); qlen = (qt - qh + 2048) % 2048; endfunction

  reg [7:0] in_byte, out_sh;
  reg [2:0] in_bits = 0, out_bits = 0;
  reg [7:0] cmd [0:5];
  integer   cmd_n = 0;
  reg       idle = 1, high_speed = 0, hs_pending = 0;
  integer   acmd41_tries = 0;
  reg       app = 0;
  reg       streaming = 0;
  reg [31:0] stream_sec;
  integer   setup_errors = 0, commands = 0;
  real      t_mosi = 0;

  always @(mosi) t_mosi = $realtime;

  task put_block(input [31:0] s); integer i; begin
    put(8'hFF); put(8'hFF); put(8'hFF);   // access latency
    put(8'hFE);
    for (i = 0; i < 512; i = i + 1) put(sd_byte(s, i));
    put(8'h00); put(8'h00);               // CRC (not checked)
  end endtask

  task command; reg [5:0] c; reg [31:0] a; integer i; begin
    c = cmd[0][5:0];
    a = {cmd[1], cmd[2], cmd[3], cmd[4]};
    commands = commands + 1;
    qh = qt;                       // a command ends what was being sent
    if (c == 12) begin
      streaming = 0;
      put(8'hFF);                  // stuff byte
      put(8'h00);                  // R1
      put(8'h00); put(8'h00);      // busy
    end else begin
      put(8'hFF);                  // NCR
      if (app && c == 41) begin
        acmd41_tries = acmd41_tries + 1;
        if (acmd41_tries >= 3) idle = 0;
        put({7'd0, idle});
      end else case (c)
        0:  begin idle = 1; streaming = 0; high_speed = 0; hs_pending = 0; put(8'h01); end
        8:  begin put({7'd0, idle}); put(8'h00); put(8'h00); put(8'h01); put(a[7:0]); end
        55: put({7'd0, idle});
        58: begin put({7'd0, idle}); put(8'hC0); put(8'hFF); put(8'h80); put(8'h00); end
        9:  begin   // CSD v2: C_SIZE = 2047 (1 GB)
              put(8'h00); put(8'hFF); put(8'hFE);
              put(8'h40); put(8'h0E); put(8'h00); put(8'h32); put(8'h5B); put(8'h59); put(8'h00);
              put(8'h00); put(8'h07); put(8'hFF);
              for (i = 0; i < 6; i = i + 1) put(8'h00);
              put(8'h00); put(8'h00);
            end
        6:  begin   // switch status: byte 16, low nibble = group 1's function
              put(8'h00); put(8'hFF); put(8'hFE);
              if (a[31] && a[3:0] == 4'h1) hs_pending = 1;   // after the status block
              for (i = 0; i < 64; i = i + 1)
                put(i == 16 ? {4'h0, (a[3:0] == 4'h1) ? 4'h1 : 4'h0} : 8'h00);
              put(8'h00); put(8'h00);
            end
        17: begin put(8'h00); put_block(a); end
        18: begin put(8'h00); streaming = 1; stream_sec = a; put_block(a); stream_sec = a + 1; end
        default: put(8'h04);       // illegal command
      endcase
    end
    app = (c == 55);
  end endtask

  initial miso = 1'bz;
  always @(negedge cs_n) begin in_bits = 0; out_bits = 0; out_sh = 8'hFF; miso <= #(TODLY) 1'b1; end
  always @(posedge cs_n) begin
    miso <= #(TOH) 1'bz;
    if (hs_pending) begin high_speed = 1; hs_pending = 0; end
  end

  always @(posedge sclk) if (!cs_n) begin
    if ($realtime - t_mosi < TISU) setup_errors = setup_errors + 1;
    in_byte = {in_byte[6:0], mosi};
    in_bits = in_bits + 1;
    if (in_bits == 0) begin
      if (cmd_n == 0 && in_byte[7:6] == 2'b01) begin cmd[0] = in_byte; cmd_n = 1; end
      else if (cmd_n > 0) begin
        cmd[cmd_n] = in_byte;
        cmd_n = cmd_n + 1;
        if (cmd_n == 6) begin cmd_n = 0; command; end
      end
    end
  end

  // Next bit out after each falling edge (High Speed: rising edge, half a
  // period later): x from TOH, valid from TODLY.
  // (out_bits: bits of out_sh already shown; at CS low, a dummy 0xFF's MSB)
  reg shift_ev = 0;
  always @(negedge sclk) if (!cs_n && !high_speed) shift_ev = ~shift_ev;
  always @(posedge sclk) if (!cs_n && high_speed) #0.001 shift_ev = ~shift_ev;
  always @(shift_ev) if (!cs_n) begin
    out_bits = out_bits + 1;
    if (out_bits == 0) begin   // a byte is done: the next one's MSB
      if (streaming && qlen(0) < 4) begin put_block(stream_sec); stream_sec = stream_sec + 1; end
      if (qlen(0) > 0) begin out_sh = q[qh]; qh = (qh + 1) % 2048; end
      else out_sh = 8'hFF;
    end else out_sh = {out_sh[6:0], 1'b1};
    miso <= #(TOH) 1'bx;
    miso <= #(TODLY) out_sh[7];
  end
endmodule
