// Implementation of HDMI Auxiliary Video InfoFrame packet.
// By Sameer Puri https://github.com/sameer

// See Section 8.2.1
module auxiliary_video_information_info_frame(
  output logic [23:0] header,
  output logic [55:0] sub [3:0]
);
  assign header = {8'h0d, 8'h02, 8'h82};  // length, version, type

  // PB0-PB6 = sub0
  // PB7-13 =  sub1
  // PB14-20 = sub2
  // PB21-27 = sub3
  logic [7:0] packet_bytes [27:0];

  assign packet_bytes[0] = 8'd1 + ~(header[23:16] + header[15:8] + header[7:0] + packet_bytes[5] + packet_bytes[4] + packet_bytes[3] + packet_bytes[2] + packet_bytes[1]);
  assign packet_bytes[1] = {3'b000, 1'b1, 2'b00, 2'b10};  // 0, Video format (00 = RGB, 01 = YCbCr 4:2:2, 10 = YCbCr 4:4:4), Active format idfo prsent, No bar info, Scan info (underscan)
  assign packet_bytes[2] = {2'b00, 2'b01, 4'b1000};  // No colorimetry, Picture 4:3, Active same as picture
  assign packet_bytes[3] = {1'b1, 3'b000, 2'b10, 2'b00};  // IT content set, (extended colorimetry), full range, no known scaling
  assign packet_bytes[4] = {1'b0, 7'h02};  // 0, Video ID code 2 (720 x 480, 4:3) 4 (1280 x 720)
  assign packet_bytes[5] = {2'b01, 2'b11, 4'b0000};  // YCC Quantization: Full, Content type: Game, No pixel repetition.

  genvar i;
  generate
    for (i = 6; i < 28; i++)
    begin: pb_reserved
      assign packet_bytes[i] = 8'd0;
    end
    for (i = 0; i < 4; i++)
    begin: pb_to_sub
      assign sub[i] = {packet_bytes[6 + i*7], packet_bytes[5 + i*7], packet_bytes[4 + i*7], packet_bytes[3 + i*7], packet_bytes[2 + i*7], packet_bytes[1 + i*7], packet_bytes[0 + i*7]};
    end
  endgenerate

endmodule
