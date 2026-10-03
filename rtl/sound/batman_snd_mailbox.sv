`timescale 1ns/1ps
//============================================================================
//  Batman (Atari Games, 1990/91) - JSA III audio board A048974-01: the mailbox
//  between the 68000 and the 6502.  Two LS374 byte latches at 16A and 14A and
//  the two halves of the F74 at 17B that hold the "byte pending" flags.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.  See LICENSE, NOTICE.md.
//
//  Port style follows the Skull & Crossbones core's skullxbo_scom.sv (GPL-3.0),
//  but the mechanism differs: the JSA III has two plain parallel latches on the
//  audio header, not SCOM customs and a serial link.
//
//  Sound -> main: the 6502 writes $2A02 (/WRP), latching 16A and setting 17B/2,
//  so /AUDIRQ goes low (68000 IRQ level 6 and a status bit).  The 68000 reads
//  $260030 (/SCOM-RD = /AUDRD), which drives 16A onto its odd byte lane and
//  clears 17B/2.
//  Main -> sound: the 68000 writes $260040 (/SCOM-WR = /AUDWR), latching 14A
//  and setting 17B/1, so /AUDFULL goes low; it is wired straight to the
//  6502's /NMI and to a status bit.  The 6502 reads $2802 (/RDP) to clear it.
//
//  Easy to get wrong:
//   - /RESET does not reach 17B (preset tied high, clears are /RDP and
//     /AUDRD), so a pending flag survives a sound-board reset.
//   - /NMI is a level here; the 6502 model does the edge detection.  A command
//     written during reset gives no NMI until the flag is cleared and set again.
//   - No flow control: a second write before the read overwrites the byte.
//  Flags are exported active high ("pending"); batman_sound forms the board's
//  active-low nets.
//============================================================================

module batman_snd_mailbox
(
	input  logic        clk,

	// ================= the AUDIO / JAUD header, main-board side ============
	input  logic        scom_wr,       // pin 5  /SCOM-WR = /AUDWR, one clk wide
	input  logic  [7:0] scom_wr_data,  // pins 6-13 D7..D0 during that write
	input  logic        scom_rd,       // pin 4  /SCOM-RD = /AUDRD, one clk wide
	output logic  [7:0] scom_rd_data,  // pins 6-13, 16A's Q while /AUDRD
	output logic        audirq_n,      // pin 3  /AUDIRQ -> /IPL1 and /STATUS D4
	output logic        audfull_n,     // pin 2  /AUDFULL -> /STATUS D5
	input  logic        sndres,        // pin 1  /SNDRES asserted (1 = 6502 held)

	// ================= the 6502 side =======================================
	input  logic        sel_rdp,       // /RDP ($2802): 14A /OC, 17B/1 /CLR
	input  logic        sel_wrp,       // /WRP ($2A02): 16A CLK, 17B/2 CLK
	input  logic  [7:0] sd,            // SD7:0 at that access
	output logic  [7:0] rdp_data,      // 14A's Q onto SD7:0 while /RDP
	output logic        nmi_n,         // 6502 pin 6 = /AUDFULL, a level

	// ---- the two flags, active high, for the LS240 13A ----
	output logic        audfull,       // 1 = a main->sound byte is pending
	output logic        audirq         // 1 = a sound->main byte is pending
);

	// ---- 16A LS374 + 17B/2 : sound -> main ---------------------------------
	// CLK = /WRP, /CLR = /AUDRD.  The clear is asynchronous on the F74, so it
	// wins over a coincident set: applied last.
	// Plain always, not always_ff: these registers have no reset on the board
	// and take their power-up value from an initial block, which always_ff
	// does not allow.
	logic [7:0] s2m_data;
	initial begin s2m_data = 8'h00; audirq = 1'b0; end
	always @(posedge clk) begin
		if (sel_wrp) begin
			s2m_data <= sd;
			audirq   <= 1'b1;
		end
		if (scom_rd) audirq <= 1'b0;
	end

	// ---- 14A LS374 + 17B/1 : main -> sound ---------------------------------
	// CLK = /AUDWR, /CLR = /RDP; the clear wins, as above.
	logic [7:0] m2s_data;
	initial begin m2s_data = 8'h00; audfull = 1'b0; end
	always @(posedge clk) begin
		if (scom_wr) begin
			m2s_data <= scom_wr_data;
			audfull  <= 1'b1;
		end
		if (sel_rdp) audfull <= 1'b0;
	end

	// The LS374 /OC enables are applied by the read muxes on each side.
	assign scom_rd_data = s2m_data;
	assign rdp_data     = m2s_data;

	// The board's own active-low nets.
	assign audirq_n  = ~audirq;
	assign audfull_n = ~audfull;

	// 6502 pin 6 is wired directly to 17B/1 /Q: a level, not a pulse.
	assign nmi_n = ~audfull;

	// /SNDRES reaches the 6502 and the three control latches only.  It is a
	// port here so one module owns the whole header; it does not clear 17B.
	wire _unused_mbx = &{ 1'b0, sndres };

endmodule
