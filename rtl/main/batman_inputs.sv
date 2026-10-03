`timescale 1ns/1ps
//============================================================================
//  Batman controls, status word and output latch: the 74LS257 muxes at 1P, 2P
//  and 2S, the empty 1R/S expansion socket and the 74LS273 output latch at 1S
//  (from the schematic, page 42).
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.  Structure follows the Skull &
//  Crossbones MiSTer core (GPL-3.0); see NOTICE.md.
//
//  All LS257s select with MA1 (0 = A inputs).  Controls are active low.
//    0x260000 D15:8  P1 {UP, DN, LF, RT, ACTB, ACTA(jump), FIRE, START}
//    0x260002 D15:8  P2, same order (wired on the board, unused by the game)
//    0x260010 D7:4   {/VBLANK, /S-TEST, /AUDFULL, /AUDIRQ}
//    0x260012 D7:4   {float, float, /SERVICE2, /SERVICE}
//  Bits not listed are the floating bus.  MAME ignores A1 on the status read.
//  LS273 at 1S: clocked on the rising (releasing) edge of /LATCH, cleared by
//  /SYSRES.  Only D0, D1, D4, D8, D11..D14 reach it (coin counters, /SNDRES,
//  VCR jumper, graphics bank, alpha bank).  The strobes are not R/W qualified,
//  so a read of 0x260050 also clocks the latch.
//============================================================================

module batman_inputs (
	input  logic        clk,          // clk_sys
	input  logic        sysres_n,     // the /SYSRES net, 1S pin 1 (/CLR)

	// ---- the LS257 select ----
	input  logic        ma1,          // MA1, pin 1 of all four positions

	// ---- the controls, ACTIVE HIGH = "pressed" here ----
	input  logic  [3:0] p1_joy,       // {up, down, left, right}
	input  logic  [3:0] p2_joy,
	input  logic        p1_fire,      // JAMMA 22 FIRE1 ("START/FIRE")
	input  logic        p1_acta,      // JAMMA 23 ACTA1 ("JUMP")
	input  logic        p1_actb,      // JAMMA 24 ACTB1 (not in the harness)
	input  logic        p1_start,     // JAMMA 17 STRT1 ("JAMMA START 1"; MAME calls it unused)
	input  logic        p2_fire,      // JAMMA Z
	input  logic        p2_acta,      // JAMMA AA
	input  logic        p2_actb,      // JAMMA BB
	input  logic        p2_start,     // JAMMA U

	// ---- the four /STATUS sources, in their BOARD polarity ----
	input  logic        audirq_n,     // AUDIO pin 3,  ACTIVE LOW
	input  logic        audfull_n,    // AUDIO pin 2,  ACTIVE LOW
	input  logic        self_test,    // OSD / SW1, ACTIVE HIGH = "test ON"
	input  logic        service,      // JAMMA-R  /SERVICE,  ACTIVE HIGH = pressed
	input  logic        service2,     // JAMMA-CC /SERVICE2, ACTIVE HIGH = pressed
	input  logic        vblank,       // the VAD's /VBLANK, ACTIVE HIGH here

	// ---- the two device outputs ----
	output logic  [7:0] mux_dout,     // 1P/2P -> D15:8
	output logic  [3:0] stat_dout,    // 2S    -> D7:4

	// ---- the LS273 1S ----
	input  logic        latch_n,      // /LATCH, LEVEL (pin 11 takes its RISING edge)
	input  logic [15:0] latch_d,      // the 68000's D15:0 during that cycle
	output logic        cc_r,         // 1Q  D0
	output logic        cc_l,         // 2Q  D1
	output logic        sndres_n,     // 3Q  D4   AUDIO pin 1
	output logic        grbk0,        // 4Q  D11
	output logic  [2:0] albk,         // 7Q,6Q,5Q = D14,D13,D12 -> ALBK2..0
	output logic        vcr,          // 8Q  D8
	output logic  [7:0] latch_q       // the whole latch
);

	// =====================================================================
	//  1P and 2P: the player switches
	// =====================================================================
	// Active low: a pressed control pulls its JAMMA pin to ground.
	// D15..D8 = {UP, DN, LF, RT, ACTB, ACTA, FIRE, STRT}
	wire [7:0] pl1 = ~{ p1_joy[3], p1_joy[2], p1_joy[1], p1_joy[0],
	                    p1_actb,   p1_acta,   p1_fire,   p1_start };
	wire [7:0] pl2 = ~{ p2_joy[3], p2_joy[2], p2_joy[1], p2_joy[0],
	                    p2_actb,   p2_acta,   p2_fire,   p2_start };

	assign mux_dout = ma1 ? pl2 : pl1;     // S = 0 selects the A (player 1) side

	// =====================================================================
	//  2S: the /STATUS word
	// =====================================================================
	// The A side (MA1 = 0) is the machine's state; the B side (MA1 = 1) is the
	// two service buttons and two unconnected pins that float high.
	wire [3:0] stat_a = { ~vblank, ~self_test, audfull_n, audirq_n };
	wire [3:0] stat_b = { 1'b1, 1'b1, ~service2, ~service };

	wire [3:0] stat_2s = ma1 ? stat_b : stat_a;

	// The 1R/S expansion socket is empty on production boards, so 2S alone
	// drives D7:4.
	assign stat_dout = stat_2s;

	// =====================================================================
	//  1S: the 74LS273 output latch
	// =====================================================================
	logic latch_n_q;
	always_ff @(posedge clk) latch_n_q <= latch_n;
	wire latch_rise = latch_n & ~latch_n_q;    // the strobe RELEASING

	always_ff @(posedge clk) begin
		if (!sysres_n)       latch_q <= 8'h00;  // /CLR, asynchronous
		else if (latch_rise) latch_q <= { latch_d[14], latch_d[13], latch_d[12],
		                                  latch_d[11], latch_d[8],  latch_d[4],
		                                  latch_d[1],  latch_d[0] };
	end

	assign cc_r     = latch_q[0];       // 1Q  <- D0
	assign cc_l     = latch_q[1];       // 2Q  <- D1
	assign sndres_n = latch_q[2];       // 3Q  <- D4
	assign vcr      = latch_q[3];       // 8Q  <- D8
	assign grbk0    = latch_q[4];       // 4Q  <- D11
	assign albk     = latch_q[7:5];     // 7Q,6Q,5Q <- D14,D13,D12

	// D2, D3, D5, D6, D7, D9, D10 and D15 reach no latch input.
	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused_latch = &{1'b0, latch_d[15], latch_d[10:9], latch_d[7:5],
	                       latch_d[3:2], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
