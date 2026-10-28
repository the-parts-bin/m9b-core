// Implementation of HDMI audio clock regeneration packet
// By Sameer Puri https://github.com/sameer

// See HDMI 1.4b Section 5.3.3
module audio_clock_regeneration_packet(
  output logic [23:0] header,
  output logic [55:0] sub [3:0]
);
  // See Section 7.2.3, values derived from "Other" row in Tables 7-1, 7-2, 7-3.
  localparam bit [19:0] N = 6144;
  localparam bit [19:0] CTS = 27000;   // 27 MHz pixel clock, 48 kHz

  // "An HDMI Sink shall ignore bytes HB1 and HB2 of the Audio Clock Regeneration Packet header."
  assign header = {8'h00, 8'h00, 8'h01};

  // "The four Subpackets each contain the same Audio Clock regeneration Subpacket."
  genvar i;
  generate
    for (i = 0; i < 4; i++)
    begin: same_packet
      // 0x00 0x18 0x00 0x78 0x69 0x00 0x00
      assign sub[i] = {N[7:0], N[15:8], {4'd0, N[19:16]}, CTS[7:0], CTS[15:8], {4'd0, CTS[19:16]}, 8'd0};
    end
  endgenerate

endmodule
