module gpu(
  input logic rst,
  input logic system_clk,
  input logic[11:0] cx,
  input logic[9:0] cy,
  output logic[23:0] rgb
);

  // The system has 26 RAM blocks.
  // We want to be able to do the following:
  // 1280x720 32bpp: 5120 bytes / scanline
  // 8-bit palette: pixel + palette lookups at pixel_clk
  // 3-channel lookup: pixel + 3 lookups at pixel_clk
  // Text mode: 80x23 chars+attributes: 2 * 1840 = 3680 bytes. char rom 16 * 256 = 4096 bytes
  // Audio will need 2 x 128 byte buffers, which would need refreshing at 1.5 kHz
  //   Scanlines run at 99 kHz, so that would be one audio buffer every 66 scanlines.
  
  logic [10:0] gpu_mem_addr[0:3];
  logic [15:0] gpu_mem_rd_data[0:3];
  logic [31:0] sys_mem_rd_data[0:3];
  logic gpu_mem_ce[0:3] = {1'b0, 1'b0, 1'b0, 1'b0};

  genvar i;
  generate
    for (i = 0; i < 4; i++) begin: gpu_ram_blk
      gpu_ram gpu_ram_0(
        .clka(system_clk),          //input clka
        .ada(gpu_mem_addr[i]),      //input [10:0] ada
        .dina(16'h0),               //input [15:0] dina
        .douta(gpu_mem_rd_data[i]), //output [15:0] douta
        .ocea(1'b1),                //input ocea
        .cea(gpu_mem_ce[i]),                //input cea
        .reseta(rst),               //input reseta
        .wrea(1'b0),                //input wrea

        .clkb(system_clk),          //input clkb
        .adb(10'h0),                //input [9:0] adb
        .dinb(16'h0),               //input [31:0] dinb
        .doutb(sys_mem_rd_data[i]), //output [31:0] doutb
        .oceb(1'b0),                //input oceb
        .ceb(1'b0),                 //input ceb
        .resetb(rst),               //input resetb
        .wreb(1'b0)                 //input wreb
      );
    end
  endgenerate

  logic [7:0] font_rom_rd_data;
  logic [10:0] font_rom_addr;

  font_rom font_rom_instance(
      .dout(font_rom_rd_data),  // output [7:0] dout
      .clk(system_clk),         // input clk
      .oce(1'b1),               // input oce
      .ce(1'b1),                // input ce
      .reset(rst),              // input reset
      .ad(font_rom_addr)        // input [10:0] ad
  );

  logic font_bit;

  // font_rom_addr is registered from cx (1 cycle), and font_rom itself
  // (READ_MODE=0) adds one more cycle of registered-output latency, so
  // font_rom_rd_data reflects cx as it was 2 cycles ago. The bit-select
  // index has to be delayed by the same 2 cycles, or it ends up paired
  // with the wrong glyph byte (this was rotating the rendered character
  // by one bit).
  logic [2:0] font_col_d0, font_col_d1;
  wire [11:0] cx_ahead = cx + 12'd3;

  always_ff @(posedge system_clk) begin
    // cx is in pixels (one cycle per pixel); characters are drawn 16x16
    // (the 8x8 font doubled). The glyph bit reaches rgb 3 cycles after its
    // address is formed (address register, ROM read, font_bit register),
    // while the gradients use cx directly, so the font is looked up for
    // cx + 3.
    font_rom_addr <= (cx_ahead[10:4] << 4) + cy[4:1];
    font_col_d0   <= cx_ahead[3:1];
    font_col_d1   <= font_col_d0;
    font_bit      <= font_rom_rd_data[7-font_col_d1];
    rgb <= {font_bit,font_bit,font_bit,font_bit,font_bit,font_bit,font_bit,font_bit, 8'(cx[7:0]), 8'(cy)};
  end

endmodule