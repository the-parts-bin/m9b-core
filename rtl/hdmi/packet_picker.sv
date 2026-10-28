// Implementation of HDMI packet choice logic.
// By Sameer Puri https://github.com/sameer

module packet_picker (
  input logic system_clk,
  input logic reset,
  input logic video_field_end,
  input logic packet_enable,
  input logic [4:0] packet_pixel_counter,
  input logic [15:0] audio_sample_data[1:0][1:0],
  input logic [6:0] audio_frame_counter,
  input logic audio_sample_ready,
  output logic [23:0] header,
  output logic [55:0] sub [3:0],
  output logic audio_sample_used
);

  // Connect the current packet type's data to the output.
  logic [7:0] packet_type = 8'd0;
  logic [23:0] headers [255:0];
  logic [55:0] subs [255:0] [3:0];
  assign header = headers[packet_type];
  assign sub[0] = subs[packet_type][0];
  assign sub[1] = subs[packet_type][1];
  assign sub[2] = subs[packet_type][2];
  assign sub[3] = subs[packet_type][3];

  // -------------------------------------------------------------------
  // NULL packet (0)
  // "An HDMI Sink shall ignore bytes HB1 and HB2 of the Null Packet Header and all bytes of the Null Packet Body."
  assign headers[0] = {8'dX, 8'dX, 8'd0};
  assign subs[0][0] = 56'dX;
  assign subs[0][1] = 56'dX;
  assign subs[0][2] = 56'dX;
  assign subs[0][3] = 56'dX;

  // -------------------------------------------------------------------
  // Audio Clock Regeneration Packet (1)
  audio_clock_regeneration_packet audio_clock_regeneration_packet(
    .header(headers[1]),
    .sub(subs[1])
  );

  // -------------------------------------------------------------------
  always_ff @(posedge system_clk) begin
    if (reset) begin
      audio_sample_used <= 1'b0;
    end else if (packet_pixel_counter == 5'd29 && packet_type == 8'h02) begin
      // Set the sample used two clocks ahead of end of packet. This ensures the ready
      // bit will be cleared in time for the next packet, but the machinery will not 
      // break the samples yet.
      audio_sample_used <= 1'b1;
    end else begin
      audio_sample_used <= 1'b0;
    end
  end
  audio_sample_packet audio_sample_packet (
    .audio_sample_data(audio_sample_data),
    .audio_frame_counter(audio_frame_counter),
    .header(headers[2]),
    .sub(subs[2])
  );

  // -------------------------------------------------------------------
  // Auxiliary Video Information packet (130 / 0x82)
  auxiliary_video_information_info_frame auxiliary_video_information_info_frame(.header(headers[130]), .sub(subs[130]));

  // -------------------------------------------------------------------
  // Audio Info Frame packet (132 / 0x84)
  audio_info_frame audio_info_frame(.header(headers[132]), .sub(subs[132]));

  // -------------------------------------------------------------------
  // "A Source shall always transmit... [an InfoFrame] at least once per two Video Fields"
  logic audio_clock_regeneration_packet_sent = 1'b0;
  logic audio_info_frame_sent = 1'b0;
  logic auxiliary_video_information_info_frame_sent = 1'b0;
  always_ff @(posedge system_clk) begin
    if (reset || video_field_end) begin
      audio_clock_regeneration_packet_sent <= 1'b0;
      audio_info_frame_sent <= 1'b0;
      auxiliary_video_information_info_frame_sent <= 1'b0;
      packet_type <= 8'dx;
    end else if (packet_enable) begin
      if (audio_sample_ready) begin
        packet_type <= 8'd2;
      end else if (!audio_info_frame_sent) begin
        packet_type <= 8'h84;
        audio_info_frame_sent <= 1'b1;
      end else if (!audio_clock_regeneration_packet_sent) begin
        packet_type <= 8'd1;
        audio_clock_regeneration_packet_sent <= 1'b1;
      end else if (!auxiliary_video_information_info_frame_sent) begin
        packet_type <= 8'h82;
        auxiliary_video_information_info_frame_sent <= 1'b1;
      end else begin
        packet_type <= 8'd0;
      end
    end
  end

endmodule
