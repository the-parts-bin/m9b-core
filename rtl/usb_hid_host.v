// From https://github.com/nand2mario/usb_hid_host (commit 678b013, Apache 2.0:
// see usb_hid_host.LICENSE). Needs exactly 12 MHz. m9b changes:
//   - Two ports, one engine: the microcode engine (ukp) runs one port at a
//     time and switches at the microcode's frame wait (see ukp below).
//     Device types are per port; the descriptor and report buffers are
//     shared.
//   - The report is kept as raw bytes 0-5 (rpt) for any device type instead
//     of decoded key/mouse/gamepad outputs.
//   - The 1 ms frame timer is outside (sof), the microcode ROM too
//     (rom_adr/rom_data), pc is 10 bits (the program is 536 nibbles).
//   - The watchdog counts frames, covers a device that never answers, is
//     cleared by reset and releases the bus when it fires (see wdt0/1); a
//     transaction that gets no answer is abandoned after about 170 us
//     (see tmo).
//   - dbg_ukp (per port: connected, output enable, line levels, pc).
// Usb_hid_host: A compact USB HID host core.
//
// nand2mario, 8/2023, based on work by hi631
//
// This should support keyboard, mouse and gamepad input out of the box, over low-speed
// USB (1.5Mbps). Just connect D+, D-, VBUS (5V) and GND, and two 15K resistors between
// D+ and GND, D- and GND. Then provide a 12Mhz clock through usbclk.
//
// See https://github.com/nand2mario/usb_hid_host
//

module usb_hid_host (
    input  usbclk,		            // 12MHz clock
    input  [1:0] usbrst_n,	        // reset, per port (m9b)
    inout  usb_dm0, usb_dp0,        // port 0's D- and D+
    inout  usb_dm1, usb_dp1,        // port 1's (m9b)
    input  sof,                     // m9b: 1 ms frame tick (one usbclk every 12002)

    output [3:0] typ,               // device types {port 1, port 0}. 0: no device, 1: keyboard, 2: mouse, 3: gamepad
    output reg report,              // pulse after report received from device
    output reg report_port,         // m9b: the port that report came from
    output [1:0] conerr,            // connection or protocol error, per port

    // m9b: bytes 0-5 of the last report (of either port: copy them on the
    // report pulse), byte 0 in bits 7:0, held until the next one. Keyboard:
    // modifiers, reserved, keys 1-4. Mouse: buttons {middle, right, left},
    // dx, dy (signed). Gamepad: device specific.
    output reg [47:0] rpt,

    // debug, per port {port 1, port 0}: {connected, oe, dm, dp, pc}
    output [27:0] dbg_ukp,

    // m9b: the microcode ROM is outside (usb_hid_host_rom): its address
    // (registered read, one usbclk later) and data
    output [9:0]  rom_adr,
    input  [3:0]  rom_data
);

wire data_rdy;          // data ready
wire data_strobe;       // data strobe for each byte
wire [7:0] ukpdat;		// actual data
reg [7:0] regs [7];     // 0 (VID_L), 1 (VID_H), 2 (PID_L), 3 (PID_H), 4 (INTERFACE_CLASS), 5 (INTERFACE_SUBCLASS), 6 (INTERFACE_PROTOCOL)
wire save;			    // save dat[b] to output register r
wire [3:0] save_r;      // which register to save to
wire [3:0] save_b;      // dat[b]
wire [1:0] connected;
wire act;               // m9b: the port the engine is running

ukp ukp(
    .usbrst_n(usbrst_n), .usbclk(usbclk),
    .usb_dp0(usb_dp0), .usb_dm0(usb_dm0), .usb_dp1(usb_dp1), .usb_dm1(usb_dm1),
    .ukprdy(data_rdy), .ukpstb(data_strobe), .ukpdat(ukpdat), .save(save), .save_r(save_r), .save_b(save_b),
    .act(act), .connected(connected), .conerr(conerr), .dbg(dbg_ukp), .sof(sof),
    .rom_adr(rom_adr), .rom_data(rom_data));

reg  [1:0] typ0 = 0, typ1 = 0;
wire [1:0] typ_act = act ? typ1 : typ0;
assign typ = {typ1, typ0};

reg  [3:0] rcvct;		// counter for recv data
reg  data_strobe_r, data_rdy_r;	// delayed data_strobe and data_rdy
reg  [7:0] dat[8];		// data in last response

// m9b: nand2mario's per-type decoding (keys, mouse, gamepad directions and
// buttons) is gone: the raw bytes go to rpt, and software decodes them.
always @(posedge usbclk) begin : process_in_data
    data_rdy_r <= data_rdy; data_strobe_r <= data_strobe;
    report <= 0;                    // ensure pulse
    if(~data_rdy) rcvct <= 0;
    else begin
        if(data_strobe && ~data_strobe_r) begin  // rising edge of ukp data strobe
            dat[rcvct] <= ukpdat;
            if (typ_act != 0 && rcvct < 6)
                rpt[rcvct*8 +: 8] <= ukpdat;
            rcvct <= rcvct + 1;
        end
    end
    if(~data_rdy && data_rdy_r && typ_act != 0) begin   // falling edge of ukp data ready
        report <= 1;
        report_port <= act;         // (the engine only switches ports at a frame wait)
    end
end

// m9b: the descriptor fields are saved and checked within one burst of
// transactions (no frame wait in between), so one set of regs serves both
// ports; only the result, the type, is per port.
reg save_delayed;
reg [1:0] connected_r;
reg [1:0] typ_new;
always @(*) begin
    if (regs[4] == 3) begin  // bInterfaceClass. 3: HID, other: non-HID
        if (regs[5] == 1)    // bInterfaceSubClass. 1: Boot device
            typ_new = regs[6] == 1 ? 1 : 2;     // bInterfaceProtocol. 1: keyboard, 2: mouse
        else
            typ_new = 3;       // gamepad
    end else
        typ_new = 0;
end
always @(posedge usbclk) begin : response_recognition
    save_delayed <= save;
    if (save) begin
        regs[save_r] <= dat[save_b];
    end else if (save_delayed && ~save && save_r == 6) begin
        // falling edge of save for bInterfaceProtocol
        if (act) typ1 <= typ_new; else typ0 <= typ_new;
    end
    connected_r <= connected;
    if (~connected[0] & connected_r[0]) typ0 <= 0;   // clear device type on disconnect
    if (~connected[1] & connected_r[1]) typ1 <= 0;
end

endmodule

// m9b: two ports, one engine. The microcode polls a device every few frames
// (1 ms) and sends a keep-alive in the others, waiting for the next frame
// with WAIT; in between it runs one burst of transactions. So one engine
// serves both ports: when the running port reaches a WAIT whose frame hasn't
// come yet and the other port has one pending (tick), the engine swaps the
// running port's context (pc, wpc, wk, conn) with the other's (spc, swpc,
// swk, sconn) and carries on with that port. Nothing else is live across a
// WAIT except what each port keeps for itself: its bus drive (ug/up/um: a
// bus reset holds SE0 across frames), its watchdog and its device type. A
// port held in reset gives the engine to the other. One port's burst delays
// the other's by a transaction or two (tens of us); a device that doesn't
// answer is cut short by the transaction timeout (tmo) instead of holding
// the engine until its watchdog fires.
module ukp(
    input [1:0] usbrst_n,
    input usbclk,				// 12MHz clock
    inout usb_dp0, usb_dm0,		// D+, D-, port 0
    inout usb_dp1, usb_dm1,		// port 1
    output reg ukprdy, 			// data frame is outputing
    output ukpstb,				// strobe for a byte within the frame
    output reg [7:0] ukpdat,	// output data when ukpstb=1
    output reg save,			// save: regs[save_r] <= dat[save_b]
    output reg [3:0] save_r, save_b,
    output reg act = 0,         // the port running
    output [1:0] connected,
    output [1:0] conerr,
    output [27:0] dbg,
    input  sof,                 // 1 ms frame tick
    output [9:0]  rom_adr,      // the ROM is outside (see usb_hid_host)
    input  [3:0]  rom_data
);

    parameter S_OPCODE = 0;
    parameter S_LDI0 = 1;
    parameter S_LDI1 = 2;
    parameter S_B0 = 3;
    parameter S_B1 = 4;
    parameter S_B2 = 5;
    parameter S_S0 = 6;
    parameter S_S1 = 7;
    parameter S_S2 = 8;
    parameter S_TOGGLE0 = 9;
    parameter S_TOGGLE1 = 10;

    wire [3:0] inst;
    reg  [3:0] insth;
    wire sample;						// 1: an IN sample is available
    reg inst_ready = 0, cond = 0, nak = 0, dmis = 0;
    reg nrzon;
    reg [1:0] mbit = 0;					// 1: out4/outb is transmitting
    reg [3:0] state = 0;
    reg [7:0] sb = 0;					// out value
    reg [3:0] sadr;						// out4/outb write ptr
    reg [2:0] timing = 0;				// T register (0~7)
    reg [3:0] lb4 = 0, lb4w;
    reg [6:0] bitadr = 0;				// 0~127
    reg [7:0] data = 0;					// received data
    reg [2:0] nrztxct, nrzrxct;			// NRZI trans/recv count for bit stuffing

    // m9b: the running port's context, and the other port's
    reg [9:0] pc = 0, wpc;				// program counter, wpc = next pc
    reg [7:0] wk = 0;					// W register
    reg conn = 0;						// connected
    reg [9:0] spc = 0, swpc;
    reg [7:0] swk = 0;
    reg sconn = 0;
    // m9b: per port
    reg [1:0] ug = 0, up = 0, um = 0;	// ug=1: output enabled, 0: hi-Z
    reg [1:0] tick = 0;					// a frame started while the port waited, not running
    reg [9:0] wdt0 = 0, wdt1 = 0;		// watchdogs: frames since the last answer
    reg dp0r, dm0r, dp1r, dm1r;			// line levels, registered
    wire dpi = act ? dp1r : dp0r;
    wire dmi = act ? dm1r : dm0r;
    wire ug_a = ug[act], up_a = up[act];
    wire [9:0] wdt_a = act ? wdt1 : wdt0;
    wire rst_a = ~usbrst_n[act], rst_o = ~usbrst_n[~act];

    wire at_wait = inst_ready & state == S_OPCODE & inst == 14;
    wire go = sof | tick[act];			// this port's next frame has come
    wire swap = at_wait & ~go & tick[~act] & ~rst_o;
    wire next = ~(state == S_OPCODE & (
        inst ==2 & dmi |								// start
        (inst==4 || inst==5) & timing != 0 |			// out0/hiz
        inst ==13 & (~sample | (dpi | dmi) & wk != 1) |	// in
        inst ==14 & ~go									// wait
    ));
    wire branch = state == S_B1 & cond;
    wire retpc  = state == S_OPCODE && inst==7  ? 1 : 0;
    wire jmppc  = state == S_OPCODE && inst==15 ? 1 : 0;
    wire dbit   = sb[7-sadr[2:0]];
    reg  dmid;
    reg  ukprdyd;
    // m9b: transaction timeout, from START until the RET that ends the
    // receive routine (normally under 1100 cycles: the answer, up to 104
    // bits and the end of packet); then back to the start of the program,
    // as the watchdog would do much later.
    reg  xfer = 0;
    reg [10:0] tmo = 0;
    wire abort = xfer & (&tmo);
    wire wdt_fire = wdt_a[9:8] == 2'b11;
    // m9b: START only counts once the reply begins (D- low), so a device
    // that never answers trips the watchdog (and the program restarts).
    wire answered = ukprdy && ~ukprdyd || inst_ready && state == S_OPCODE && inst == 4'b0010 && ~dmi;

    assign conerr = {wdt1[9] | ~usbrst_n[1], wdt0[9] | ~usbrst_n[0]};
    assign connected = act ? {conn, sconn} : {sconn, conn};

    assign rom_adr = pc;
    assign inst = rom_data;

    always @(posedge usbclk) begin
        dp0r <= usb_dp0; dm0r <= usb_dm0; dp1r <= usb_dp1; dm1r <= usb_dm1;
        save <= 0;		// ensure pulse
        ukprdyd <= ukprdy;
        if (sof) tick[~act] <= 1;
        // Watchdogs: both count frames until they fire (the waiting port's
        // fires once it runs again); an answer clears the running port's
        if (sof && wdt0[9:8] != 2'b11) wdt0 <= wdt0 + 1;
        if (sof && wdt1[9:8] != 2'b11) wdt1 <= wdt1 + 1;
        if (answered) begin if (act) wdt1 <= 0; else wdt0 <= 0; end
        tmo <= xfer ? tmo + 1 : 0;

        if (rst_a & rst_o) begin
            pc <= 0; conn <= 0; spc <= 0; sconn <= 0; cond <= 0; inst_ready <= 0; state <= S_OPCODE; timing <= 0;
            mbit <= 0; bitadr <= 0; nak <= 1; ug <= 0; tick <= 0; xfer <= 0;
            wdt0 <= 0; wdt1 <= 0;     // or it can fire mid-sequence after a reset
        end else if (rst_a) begin
            // The running port is held in reset: run the other one
            pc <= spc; wpc <= swpc; wk <= swk; conn <= sconn;
            spc <= 0; sconn <= 0;
            act <= ~act;
            inst_ready <= 0; state <= S_OPCODE; mbit <= 0; nak <= 1; xfer <= 0;
            ug[act] <= 0; tick[act] <= 0;
            if (act) wdt1 <= 0; else wdt0 <= 0;
        end else if (wdt_fire | abort) begin
            // !! WDT ON (m9b: and release the bus), or the transaction timeout
            pc <= 0; ug[act] <= 0; mbit <= 0; state <= S_OPCODE; inst_ready <= 0; xfer <= 0;
            if (wdt_fire) begin if (act) wdt1 <= 0; else wdt0 <= 0; end
        end else if (swap) begin
            pc <= spc; wpc <= swpc; wk <= swk; conn <= sconn;
            spc <= pc; swpc <= wpc; swk <= wk; sconn <= conn;
            act <= ~act;
            inst_ready <= 0;
        end else begin
            if (inst_ready) begin
                // Instruction decoding
                case(state)
                    S_OPCODE: begin
                        insth <= inst;
                        if(inst==1) state <= S_LDI0;						// op=ldi
                        if(inst==3) begin sadr <= 3; state <= S_S0; end		// op=out4
                        if(inst==4) begin ug[act] <= 1; up[act] <= 0; um[act] <= 0; end
                        if(inst==5) begin ug[act] <= 0; end
                        if(inst==6) begin sadr <= 7; state <= S_S0; end		// op=outb
                        if (inst[3:2]==2'b10) begin							// op=10xx(BZ,BC,BNAK,DJNZ)
                            state <= S_B0;
                            case (inst[1:0])
                                2'b00: cond <= ~dmi;
                                2'b01: cond <= conn;
                                2'b10: cond <= nak;
                                2'b11: cond <= wk != 1;
                            endcase
                        end
                        if(inst==11 | inst==13 & sample) wk <= wk - 8'd1;	// op=DJNZ,IN
                        if(inst==15) begin state <= S_B2; cond <= 1; end	// op=jmp
                        if(inst==12) state <= S_TOGGLE0;
                        if(inst==14 & go) tick[act] <= 0;					// op=wait (m9b)
                        if(inst==2) xfer <= 1;								// op=start (m9b)
                    end
                    // Instructions with operands
                    // ldi
                    S_LDI0: begin	wk[3:0] <= inst; state <= S_LDI1;	end
                    S_LDI1: begin	wk[7:4] <= inst; state <= S_OPCODE; end
                    // branch/jmp
                    S_B2: begin lb4w <= inst; state <= S_B0; end
                    S_B0: begin lb4  <= inst; state <= S_B1; end
                    S_B1: state <= S_OPCODE;
                    // out
                    S_S0: begin sb[3:0] <= inst; state <= S_S1; end
                    S_S1: begin sb[7:4] <= inst; state <= S_S2; mbit <= 1; end
                    // toggle and save
                    S_TOGGLE0: begin
                        if (inst == 15) conn <= ~conn;			// toggle
                        else save_r <= inst;                    // save
                        state <= S_TOGGLE1;
                      end
                    S_TOGGLE1: begin
                        if (inst != 15) begin
                            save_b <= inst;
                            save <= 1;
                        end
                        state <= S_OPCODE;
                    end
                endcase
                // pc control
                if (mbit==0) begin
                    if(jmppc) wpc <= pc + 4;
                    if (next | branch | retpc) begin
                        if(retpc) begin pc <= wpc; xfer <= 0; end	// ret
                        else if(branch)
                            if(insth==15)						// jmp
                                pc <= { lb4, lb4w, 2'b00 };		// m9b: inst (bits 13:10) is 0
                            else								// branch
                                pc <= { inst, lb4, 2'b00 };
                        else	pc <= pc + 1;					// next
                        inst_ready <= 0;
                    end
                end
            end
            else inst_ready <= 1;
            // bit transmission (out4/outb)
            if (mbit==1 && timing == 0) begin
                if(ug_a==0) nrztxct <= 0;
                else
                    if(dbit) nrztxct <= nrztxct + 1;
                    else     nrztxct <= 0;
                if(insth == 4'd6) begin
                    if(nrztxct!=6) begin up[act] <= dbit ?  up_a : ~up_a; um[act] <= dbit ? ~up_a :  up_a; end
                    else           begin up[act] <= ~up_a; um[act] <= up_a; nrztxct <= 0; end
                end else begin
                    up[act] <=  sb[{1'b1,sadr[1:0]}]; um[act] <= sb[sadr[2:0]];
                end
                ug[act] <= 1'b1;
                if(nrztxct!=6) sadr <= sadr - 4'd1;
                if(sadr==0) begin mbit <= 0; state <= S_OPCODE; end
            end
            // start instruction
            dmid <= dmi;
            if (inst_ready & state == S_OPCODE & inst == 4'b0010) begin // op=start
                bitadr <= 0; nak <= 1; nrzrxct <= 0;
            end else
                if(ug_a==0 && dmi!=dmid) timing <= 1;
                else                     timing <= timing + 1;
            // IN instruction
            if (sample) begin
                if (bitadr == 8) nak <= dmi;
                if(nrzrxct!=6) begin
                    data[6:0] <= data[7:1];
                    data[7] <= dmis ~^ dmi;		    // ~^/^~ is XNOR, testing bit equality
                    bitadr <= bitadr + 1; nrzon <= 0;
                end else nrzon <= 1;
                dmis <= dmi;
                if(dmis ~^ dmi) nrzrxct <= nrzrxct + 1;
                else           nrzrxct <= 0;
                if (~dmi && ~dpi) ukprdy <= 0;      // SE0: packet is finished. Mouses send length 4 reports.
            end
            if (ug_a==0) begin
                if(bitadr==24) ukprdy <= 1;			// ignore first 3 bytes
                if(bitadr==88) ukprdy <= 0;			// output next 8 bytes
            end
            if ((bitadr>11 & bitadr[2:0] == 3'b000) & (timing == 2)) ukpdat <= data;
        end
        // m9b: the waiting port held in reset
        if (rst_o & ~rst_a) begin
            spc <= 0; sconn <= 0; ug[~act] <= 0; tick[~act] <= 0;
            if (act) wdt0 <= 0; else wdt1 <= 0;
        end
    end

    assign usb_dp0 = ug[0] ? up[0] : 1'bZ;
    assign usb_dm0 = ug[0] ? um[0] : 1'bZ;
    assign usb_dp1 = ug[1] ? up[1] : 1'bZ;
    assign usb_dm1 = ug[1] ? um[1] : 1'bZ;
    assign sample = inst_ready & state == S_OPCODE & inst == 4'b1101 & timing == 4; // IN
    assign ukpstb = ~nrzon & ukprdy & (bitadr[2:0] == 3'b100) & (timing == 2);
    wire [9:0] pc0 = act ? spc : pc, pc1 = act ? pc : spc;
    assign dbg = {connected[1], ug[1], dm1r, dp1r, pc1, connected[0], ug[0], dm0r, dp0r, pc0};
endmodule
