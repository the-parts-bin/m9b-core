// Video RAM: 4 KB (words 512..1535 of a 1536-word space), written by the
// CPU (word writes only, no byte enables) and read by the video engine on
// the pixel clock (registered read). Two explicit 512-word banks, one BSRAM
// each. Initialized from vram_init1/2.hex (see gen_vram_init.py). Layout
// (byte addresses):
//   0x0000 - 0x07FF : unused (the text mode's font, removed; writes are
//                     dropped, reads give the palette bank's data)
//   0x0800 - 0x09FF : palette, 256 x RGB565, entry i at 0x800 + 2 i
//   0x0A00 - 0x153F : per-line table, 720 x 32-bit entries (see
//                     video_engine.v)

module vram (
  input  wire        wclk,
  input  wire        we,
  input  wire [10:0] waddr,
  input  wire [31:0] wdata,
  input  wire        rclk,
  input  wire [10:0] raddr,
  output wire [31:0] rdata
);

  reg [31:0] bank1 [0:511];
  reg [31:0] bank2 [0:511];
  reg [31:0] q1, q2;
  reg        rbank2;

  initial begin
    $readmemh("vram_init1.hex", bank1);
    $readmemh("vram_init2.hex", bank2);
  end

  always @(posedge wclk) begin
    if (we && waddr[10:9] == 2'd1) bank1[waddr[8:0]] <= wdata;
    if (we && waddr[10:9] == 2'd2) bank2[waddr[8:0]] <= wdata;
  end

  always @(posedge rclk) begin
    q1 <= bank1[raddr[8:0]];
    q2 <= bank2[raddr[8:0]];
    rbank2 <= raddr[10];
  end

  assign rdata = rbank2 ? q2 : q1;

endmodule
