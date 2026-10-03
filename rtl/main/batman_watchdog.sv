`timescale 1ns/1ps
//============================================================================
//  Batman power-on reset and watchdog: the R80/C115/Q7 POWER-ON node
//  (schematic page 41) and the 74LS197 counter at 12N/P (page 44).
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.  Structure follows the Skull &
//  Crossbones MiSTer core (GPL-3.0); see NOTICE.md.
//
//  The LS197 counts falling edges of /VBLANK; QD is /SYSRES.  POWER-ON clears
//  it to 0 (async), any /WDOG access (read or write) loads 8, and QD falls on
//  the wrap 15 -> 0, so the timeout is 8 frames (~133 ms).  MAME uses its
//  3-frame default instead.  Power-on reset lasts ~10 ms (R80 x C115) plus 8
//  frames, because the clear goes to 0, not 8.  /SYSRES reaches the 68000,
//  the EEPROM unlock flop and the LS273 at 1S; it does not reset the VAD.
//============================================================================

module batman_watchdog #(
	// clk_sys, for turning POR_US into a cycle count
	parameter int CLK_HZ  = 57272727,
	// ~10 ms: R80 x C115 time constant (estimated from the part values)
	parameter int POR_US  = 10000,
	// 1 = the WDOG 2-pad strap is fitted, which defeats the watchdog
	parameter bit WDOG_STRAP = 1'b0
)(
	input  logic       clk,        // clk_sys
	input  logic       ext_reset,  // MiSTer only: OSD reset / ROM download re-runs the POR
	input  logic       vblank,     // the VAD's /VBLANK, ACTIVE HIGH here
	input  logic       wdog_n,     // F138 5/6K Y5, LEVEL, active low

	output logic       sysres_n,   // the /SYSRES net, ACTIVE LOW
	output logic       power_on,   // the POWER-ON node, ACTIVE HIGH
	output logic [3:0] count       // QD..QA
);

	// ---------------- the POWER-ON node -----------------------------------
	localparam int POR_CYCLES = int'((longint'(POR_US) * CLK_HZ) / 1000000);
	localparam int POR_W      = (POR_CYCLES <= 1) ? 1 : $clog2(POR_CYCLES + 1);

	logic [POR_W-1:0] por_cnt;
	logic             por_done;

	always_ff @(posedge clk) begin
		if (ext_reset) begin
			por_cnt  <= '0;
			por_done <= 1'b0;
		end else if (!por_done) begin
			if (por_cnt >= POR_W'(POR_CYCLES - 1)) por_done <= 1'b1;
			else                                   por_cnt  <= por_cnt + 1'b1;
		end
	end

	// POWER-ON is low until C115 charges; it drives the LS197 /CLR directly.
	assign power_on = por_done;

	// ---------------- the /WDOG node and the strap -----------------------
	// The strap grounds the /WDOG node (R75 pulls it up).
	wire wdog_lvl_n = WDOG_STRAP ? 1'b0 : wdog_n;

	// ---------------- 74LS197 12N/P ---------------------------------------
	// /VBLANK falls at the start of blanking = rising edge of active-high vblank.
	logic vblank_q;
	always_ff @(posedge clk) vblank_q <= vblank;
	wire vblank_rise = vblank & ~vblank_q;

	logic [3:0] q;
	always_ff @(posedge clk) begin
		if (!power_on)        q <= 4'd0;      // /CLR, async, DOMINATES /LD
		else if (!wdog_lvl_n) q <= 4'd8;      // /LD, async, D C B A = 1000
		else if (vblank_rise) q <= q + 4'd1;  // wraps 15 -> 0 and drops QD
	end

	assign count    = q;
	assign sysres_n = q[3];                   // QD (pin 12)

endmodule
