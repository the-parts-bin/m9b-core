// Implementation of HDMI audio sample packet
// By Sameer Puri https://github.com/sameer

// Unless otherwise specified, all "See X" references will refer to the HDMI v1.4a specification.

// See Section 5.3.4
// 2-channel L-PCM or IEC 61937 audio in IEC 60958 frames with consumer grade IEC 60958-3.
module audio_sample_packet(
  input logic [15:0] audio_sample_data[1:0] [1:0],
  input logic [6:0] audio_frame_counter,
  output logic [23:0] header,
  output logic [55:0] sub [3:0]
);
  // See IEC 60958-3 5.2.2, Table 2
  logic [191:0] channel_status_left;
  assign channel_status_left = {
    152'd0,
    4'b0, 4'b0010,  // ORIGINAL_SAMPLING_FREQUENCY, WORD_LENGTH, 
    2'b00, 2'b00, 4'b0010,  // CLOCK_ACCURACY, SAMPLING_FREQUENCY, 
    4'd1, 4'd0,  // CHANNEL_LEFT, SOURCE_NUMBER,
    8'd0,  // CATEGORY_CODE,
    2'b00, 3'b000, 1'b0, 1'b0, 1'b0}; // MODE, PRE_EMPHASIS, COPYRIGHT_NOT_ASSERTED, SAMPLE_WORD_TYPE, GRADE

  logic [191:0] channel_status_right;
  assign channel_status_right = {
    152'd0,
    4'b0, 4'b0010,  // ORIGINAL_SAMPLING_FREQUENCY, WORD_LENGTH, 
    2'b00, 2'b00, 4'b0010,  // CLOCK_ACCURACY, SAMPLING_FREQUENCY, 
    4'd2, 4'd0,  // CHANNEL_RIGHT, SOURCE_NUMBER,
    8'd0,  // CATEGORY_CODE,
    2'b00, 3'b000, 1'b0, 1'b0, 1'b0}; // MODE, PRE_EMPHASIS, COPYRIGHT_NOT_ASSERTED, SAMPLE_WORD_TYPE, GRADE

  // See HDMI 1.4a Table 5-12: Audio Sample Packet Header.
  assign header[7:0] = 8'd2;
  assign header[15:8] = 8'b00000011;  // 2 samples, layout 0
  assign header[23:16] = (audio_frame_counter == 7'd0) ? 8'b00010000 : 8'b00000000;  // Start of frame marker

  assign sub[2] = 56'b0;
  assign sub[3] = 56'b0;

  logic [1:0] parity_bit [3:0];
  logic [7:0] aligned_frame_counter [3:0];
  wire valid_bit = 1'b0;
  wire user_data_bit = 1'b0;
  genvar i;
  generate
    for (i = 0; i < 2; i++)
    begin: sample_based_assign
      assign aligned_frame_counter[i] = {audio_frame_counter, 1'(i)};
      assign parity_bit[i][0] = ^{channel_status_left[aligned_frame_counter[i]], user_data_bit, valid_bit, audio_sample_data[i][0]};
      assign parity_bit[i][1] = ^{channel_status_right[aligned_frame_counter[i]], user_data_bit, valid_bit, audio_sample_data[i][1]};
      // See HDMI 1.4a Table 5-13: Audio Sample Subpacket.
      always_comb begin
        sub[i] = {
          {
            parity_bit[i][1],
            channel_status_right[aligned_frame_counter[i]],
            user_data_bit,
            valid_bit,
            parity_bit[i][0],
            channel_status_left[aligned_frame_counter[i]],
            user_data_bit,
            valid_bit
          },
          {audio_sample_data[i][1], 8'b0},
          {audio_sample_data[i][0], 8'b0}
        };
      end
    end
  endgenerate

endmodule
