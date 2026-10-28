// TMDS serializers (OSER10, 10:1) for the three data channels and the
// clock channel. clk_pixel must be phase-aligned with clk_pixel_x5 (see
// top.v: it is clk_pixel_x5 through a CLKDIV /5).
module serializer (
    input logic clk_pixel,
    input logic clk_pixel_x5,
    input logic reset,
    input logic [9:0] tmds_internal [2:0],
    output logic [2:0] tmds,
    output logic tmds_clock
);
  genvar i;
  generate
    for (i = 0; i < 3; i++) begin: gowin_serialize
      OSER10 sd(
        .D0(tmds_internal[i][0]),
        .D1(tmds_internal[i][1]),
        .D2(tmds_internal[i][2]),
        .D3(tmds_internal[i][3]),
        .D4(tmds_internal[i][4]),
        .D5(tmds_internal[i][5]),
        .D6(tmds_internal[i][6]),
        .D7(tmds_internal[i][7]),
        .D8(tmds_internal[i][8]),
        .D9(tmds_internal[i][9]),
        .PCLK(clk_pixel),
        .FCLK(clk_pixel_x5),
        .RESET(reset),
        .Q(tmds[i])
      );
    end
  endgenerate
  OSER10 sd(
    .D0(1'b1),
    .D1(1'b1),
    .D2(1'b1),
    .D3(1'b1),
    .D4(1'b1),
    .D5(1'b0),
    .D6(1'b0),
    .D7(1'b0),
    .D8(1'b0),
    .D9(1'b0),
    .PCLK(clk_pixel),
    .FCLK(clk_pixel_x5),
    .RESET(reset),
    .Q(tmds_clock)
  );

endmodule
