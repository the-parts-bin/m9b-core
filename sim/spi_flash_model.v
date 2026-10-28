`timescale 1ns / 1ps
// Minimal SPI flash model (mode 0) for tb_soc.v: 0x9F returns the
// P25Q32U's JEDEC ID 85 60 16; 0x03 (read) returns byte a = a[7:0] ^ a[15:8]
// ^ 0x5A for 24-bit address a, auto-incrementing. MISO changes on the
// falling edge (plus a small delay), as a real chip does.
module spi_flash_model (
  input  wire sclk,
  input  wire cs_n,
  input  wire mosi,
  output reg  miso
);
  reg [7:0]  in_byte, cmd, out_byte;
  reg [2:0]  bitn;
  integer    nbytes;
  reg [23:0] addr;

  function [7:0] data_at(input [23:0] a); data_at = a[7:0] ^ a[15:8] ^ 8'h5A; endfunction

  initial miso = 1'bz;
  always @(negedge cs_n) begin
    bitn = 0; nbytes = 0; out_byte = 8'hFF; miso <= #3 1'b1;
  end
  always @(posedge cs_n) miso <= #3 1'bz;

  always @(posedge sclk) if (!cs_n) begin
    in_byte = {in_byte[6:0], mosi};
    bitn = bitn + 1;
    if (bitn == 0) begin
      // A whole byte has come in: decide the next one out.
      if (nbytes == 0) cmd = in_byte;
      else if (cmd == 8'h03 && nbytes <= 3) addr = {addr[15:0], in_byte};
      nbytes = nbytes + 1;
      case (cmd)
        8'h9F: out_byte = nbytes == 1 ? 8'h85 : nbytes == 2 ? 8'h60 : nbytes == 3 ? 8'h16 : 8'hFF;
        8'h03: if (nbytes >= 4) begin out_byte = data_at(addr); addr = addr + 1; end
               else out_byte = 8'hFF;
        default: out_byte = 8'hFF;
      endcase
    end
  end
  always @(negedge sclk) if (!cs_n) begin
    miso <= #5 out_byte[7 - bitn];
  end
endmodule
