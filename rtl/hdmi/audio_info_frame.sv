// Implementation of HDMI audio info frame
// By Sameer Puri https://github.com/sameer

// See Section 8.2.2
module audio_info_frame(
  output logic [23:0] header,
  output logic [55:0] sub [3:0]
);
  assign header = {8'h0a, 8'h01, 8'h84};  // length, version, type

  // PB0-PB6 = sub0
  // PB7-13 =  sub1
  // PB14-20 = sub2
  // PB21-27 = sub3
  logic [7:0] packet_bytes [27:0];

  assign packet_bytes[0] = 8'd1 + ~(header[23:16] + header[15:8] + header[7:0] + packet_bytes[5] + packet_bytes[4] + packet_bytes[3] + packet_bytes[2] + packet_bytes[1]);
  assign packet_bytes[1] = {4'b0000, 1'b0, 3'b001};  // coding type (must be zero), 0, channel count
  assign packet_bytes[2] = {3'b000, 3'b000, 2'b00};  // 0, sampling frequency (must be zero), sample size (must be zero)
  assign packet_bytes[3] = 8'h00;  // coding type extension, unused
  assign packet_bytes[4] = 8'h00;  // Channel 0 = Front Left, Channel 1 = Front Right (0-indexed)
  assign packet_bytes[5] = {1'b0, 4'b0000, 1'b0, 2'b00}; // down-mix permitted, level shift (0 db) 0, Low-Frequency Effects (ignore)

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
