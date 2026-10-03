// Adapted for Batman from the Skull & Crossbones core's rtl/sound/skullxbo_ym.sv (GPL-3.0); see NOTICE.md
`timescale 1ns/1ps
//============================================================================
//  batman_ym - the JSA III's YM2151 at 9C1 and YM3012 DAC at 8D, through jt51.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  Ported from the Bad Lands core's badlands_ym.sv (GPL-3.0), which is in turn
//  the Blasteroids core's blstroid_ym.sv: the jt51 instance and the 6502 -> YM
//  write bridge are unchanged.
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.  See LICENSE, NOTICE.md.
//
//  YM2151 wiring: OM (pin 24) = 3.579545 MHz (ce_3m58); A0 = SA0; /IC = /YAMRES
//  (10A LS273 bit 0, low out of reset); /CS = /YAM covers all of $2000-$27FF,
//  so a status read works at any mirror.  IRQ (pin 2) is open drain onto the
//  6502 /IRQ.  CT1/CT2 (pins 8, 9) are not connected on this board.
//
//  YM3012 CH1/CH2 go through unity buffers into the 4066 volume ladder, where
//  both channels are summed with equal weight into one mono node, so which of
//  jt51's xleft/xright is SH1 or SH2 cannot be heard.  xleft -> ch1 is used.
//
//  Write bridge: jt51 captures writes on cen_p1 (= ce_1m79).  The /SWR strobe
//  is already ce_1m79-qualified, so the bridge normally holds nothing; it adds
//  no latency, which matters because the firmware polls BUSY right after a
//  write.  ce_1m79 is every other ce_3m58 pulse, as jt51 expects.
//============================================================================

module batman_ym
(
	input  logic        clk,
	input  logic        cen,        // ce_3m58 = 3.579545 MHz  (YM2151 pin 24)
	input  logic        cen_p1,     // ce_1m79 = 1.7897727 MHz, aligned with cen
	input  logic        yamres_n,   // /YAMRES (10A LS273 bit 0) -> /IC of both chips

	// bus side (from batman_sound)
	input  logic        ym_cs,      // /YAM asserted
	input  logic        ym_a0,      // SA0
	input  logic        ym_we,      // /SWR & /YAM
	input  logic  [7:0] ym_dout,    // 6502 -> YM
	output logic  [7:0] ym_din,     // YM status -> 6502 (bit 7 = BUSY)

	// pin 2 -- the 6502 /IRQ wire-OR
	output logic        ym_irq,     // 1 = asserted (the pin is active low)

	// audio: CH1 / CH2 into the volume ladder, equal weight
	output logic        sample,
	output logic signed [15:0] aud_ch1,
	output logic signed [15:0] aud_ch2
);

	// ---- write bridge -------------------------------------------------------
	logic       wr_pend, wr_a0;
	logic [7:0] wr_d;
	initial begin wr_pend = 1'b0; wr_a0 = 1'b0; wr_d = 8'h00; end
	wire        wr_cap = ym_cs & ym_we;
	// Plain always, not always_ff, because these registers take their
	// power-up value from the initial block above.
	always @(posedge clk) begin
		if (~yamres_n) begin
			wr_pend <= 1'b0;
		end else if (wr_cap & ~cen_p1) begin   // strobe missed cen_p1: hold it
			wr_pend <= 1'b1; wr_a0 <= ym_a0; wr_d <= ym_dout;
		end else if (cen_p1) begin
			wr_pend <= 1'b0;                   // jt51 consumed it on cen_p1
		end
	end

	wire       wr_go   = wr_cap | wr_pend;
	wire       jt51_a0 = wr_cap ? ym_a0   : wr_a0;
	wire [7:0] jt51_d  = wr_cap ? ym_dout : wr_d;

	wire irq_n;
	wire ct1_nc, ct2_nc;
	wire signed [15:0] lo_l_nc, lo_r_nc;

	// The instance must be named u_jt51: Batman.sdc refers to
	// *u_sound|u_ym|u_jt51|...
	jt51 u_jt51 (
		.rst    (~yamres_n),      // /IC (pin 3), the chip's only reset
		.clk    (clk),
		.cen    (cen),
		.cen_p1 (cen_p1),
		.cs_n   (~wr_go),
		.wr_n   (~wr_go),
		.a0     (jt51_a0),
		.din    (jt51_d),
		.dout   (ym_din),
		.ct1    (ct1_nc),
		.ct2    (ct2_nc),
		.irq_n  (irq_n),
		.sample (sample),
		.left   (lo_l_nc),
		.right  (lo_r_nc),
		.xleft  (aud_ch1),
		.xright (aud_ch2)
	);

	// pin 2 is an open-collector pull-down on /IRQ; export it asserted-high.
	assign ym_irq = ~irq_n;

	// CT1 (8) and CT2 (9) are not connected on this board.  jt51's
	// low-resolution left/right are unused; the YM3012 gets the full-resolution
	// serial stream, which is xleft/xright.
	wire _unused_ym = &{ 1'b0, ct1_nc, ct2_nc, lo_l_nc, lo_r_nc };

endmodule
