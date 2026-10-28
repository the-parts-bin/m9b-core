// UART, 8N1, with a programmable bit period and a 16-byte receive FIFO.
//
// Registers (see soc.v):
//   DATA   read: {22'b0, tx_busy, rx_valid, rx_byte}; a read with rx_valid
//               set takes the byte out of the FIFO. write: send a byte
//               (while !tx_busy).
//   STATUS read: {29'b0, rx_overrun, rx_valid, tx_busy} (overrun: a byte was
//               dropped because the FIFO was full; cleared by writing 1)
//   DIV    bit period in clk cycles (36 MHz: reset 312 = 115200 baud,
//          0.16% fast; 39 = 921600, 24 = 1.5 Mbaud, 12 = 3 Mbaud)
//
// The CPU samples read data in the cycle after its strobe (see soc.v), so a
// DATA read pops the FIFO in that cycle, if the CPU saw a byte there.

module uart (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        rx,
  output reg         tx,
  input  wire        tx_wr,          // one-cycle strobe
  input  wire [7:0]  tx_data,
  input  wire        rx_rd,          // one-cycle strobe (DATA read)
  input  wire        div_wr,
  input  wire [15:0] div_data,
  input  wire        ovr_clr,
  output wire [7:0]  rx_data,
  output wire        rx_valid,
  output wire        tx_busy,
  output reg         rx_overrun,
  output reg  [15:0] div,
  output reg         reset_req       // "\x1bM9BRESET" received: held for a
                                     // cycle (reset the system with it)
);

  // ---------------------------------------------------------------------
  // Receiver: synchronizer, start bit detection, mid-bit sampling.
  // ---------------------------------------------------------------------
  reg  [1:0]  rx_s = 2'b11;
  wire        rxd = rx_s[1];
  reg  [15:0] rx_cnt;
  reg  [3:0]  rx_bit;      // 0: idle; 1: start bit; 2..9: data; 10: stop
  reg  [7:0]  rx_sh;
  reg         push;
  reg  [7:0]  push_data;

  always @(posedge clk) begin
    rx_s <= {rx_s[0], rx};
    push <= 1'b0;
    if (!rst_n) begin
      rx_bit <= 4'd0;
    end else if (rx_bit == 4'd0) begin
      if (!rxd) begin
        rx_bit <= 4'd1;
        rx_cnt <= {1'b0, div[15:1]};    // to the middle of the start bit
      end
    end else if (rx_cnt != 16'd0) begin
      rx_cnt <= rx_cnt - 16'd1;
    end else begin
      rx_cnt <= div - 16'd1;
      if (rx_bit == 4'd1) begin
        rx_bit <= rxd ? 4'd0 : 4'd2;    // a glitch, or a real start bit
      end else if (rx_bit != 4'd10) begin
        rx_sh <= {rxd, rx_sh[7:1]};     // LSB first
        rx_bit <= rx_bit + 4'd1;
      end else begin
        rx_bit <= 4'd0;
        if (rxd) begin                  // valid stop bit
          push <= 1'b1;
          push_data <= rx_sh;
        end
      end
    end
  end

  // ---------------------------------------------------------------------
  // Reset string: every received byte is matched against "\x1bM9BRESET",
  // independently of the FIFO and of the CPU (a hung program can still be
  // reset from the host).
  // ---------------------------------------------------------------------
  localparam [79:0] RESET_STR = 80'h1B_4D_39_42_52_45_53_45_54_00;   // ESC M 9 B R E S E T
  reg [3:0] rs_pos;
  wire [7:0] rs_want = RESET_STR[79 - 8 * rs_pos -: 8];
  always @(posedge clk) begin
    reset_req <= 1'b0;
    if (!rst_n) begin
      rs_pos <= 4'd0;
    end else if (push) begin
      if (push_data == rs_want) begin
        if (rs_pos == 4'd8) begin
          reset_req <= 1'b1;
          rs_pos <= 4'd0;
        end else begin
          rs_pos <= rs_pos + 4'd1;
        end
      end else begin
        rs_pos <= (push_data == 8'h1B) ? 4'd1 : 4'd0;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Receive FIFO, 16 bytes.
  // ---------------------------------------------------------------------
  reg  [7:0]  fifo [0:15];
  reg  [4:0]  wr_ptr, rd_ptr;
  wire        empty = wr_ptr == rd_ptr;
  wire        full  = (wr_ptr[3:0] == rd_ptr[3:0]) && (wr_ptr[4] != rd_ptr[4]);
  reg         rd_d;
  assign rx_valid = !empty;
  assign rx_data  = fifo[rd_ptr[3:0]];

  // Pop in the cycle the CPU samples the data (the one after its strobe),
  // judged by the FIFO state it sees then: a byte arriving between strobe
  // and sample is read, so it has to be popped too (deciding at the strobe
  // left it in the FIFO, and it was read twice).
  always @(posedge clk) begin
    rd_d <= rx_rd;
    if (!rst_n) begin
      wr_ptr <= 5'd0;
      rd_ptr <= 5'd0;
      rx_overrun <= 1'b0;
    end else begin
      if (push) begin
        if (!full) begin
          fifo[wr_ptr[3:0]] <= push_data;
          wr_ptr <= wr_ptr + 5'd1;
        end else begin
          rx_overrun <= 1'b1;
        end
      end
      if (rd_d && !empty) rd_ptr <= rd_ptr + 5'd1;
      if (ovr_clr) rx_overrun <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------
  // Transmitter and divider register.
  // ---------------------------------------------------------------------
  reg  [9:0]  tx_sh;
  reg  [3:0]  tx_left;     // 10 bits to send, then the stop bit's time
  reg  [15:0] tx_cnt;
  assign tx_busy = tx_left != 4'd0;

  always @(posedge clk) begin
    if (!rst_n) begin
      tx <= 1'b1;
      tx_left <= 4'd0;
      div <= 16'd312;   // 115200 baud at 36 MHz (the reset string needs it)
    end else begin
      if (div_wr) div <= div_data;
      if (tx_left == 4'd0) begin
        if (tx_wr) begin
          tx_sh <= {1'b1, tx_data, 1'b0};
          tx_left <= 4'd11;
          tx_cnt <= 16'd0;
        end
      end else if (tx_cnt != 16'd0) begin
        tx_cnt <= tx_cnt - 16'd1;
      end else begin
        tx <= tx_sh[0];
        tx_sh <= {1'b1, tx_sh[9:1]};
        tx_cnt <= div - 16'd1;
        tx_left <= tx_left - 4'd1;
      end
    end
  end

endmodule
