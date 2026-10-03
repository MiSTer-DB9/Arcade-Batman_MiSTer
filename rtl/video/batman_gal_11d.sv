`timescale 1ns/1ps
//============================================================================
//  Batman GAL16V8A 136085-1005 at 11D: motion-object line-buffer phase control
//  and the "stain" (shadow run) latch.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//  Structure follows skullxbo_prio.sv of the Skull & Crossbones MiSTer core
//  (GPL-3.0); see NOTICE.md.
//
//  The logic is transcribed from the GAL fuse map (complex mode; pins 1 and 11
//  are plain inputs; every output is active low, so the code builds each
//  output's sum sNN and drives the pin with ~sNN).  ThunderJaws' GAL 1073 has
//  the same fuse map.  The manual lacks the video sheets, so the pin names
//  below are inferred from sibling boards and MAME.
//
//  o14..o17 are cross-coupled through the array: two latch pairs, one per
//  line-buffer bank, switched by i7.  The feedback is bipartite ({s14,s16}
//  depend only on {s15,s17} and vice versa), so the model re-evaluates all
//  four sums once per clk_sys from the previous values.  That settles in two
//  clocks, well inside one pixel, has no combinational loop, and matches
//  iterating the fuse equations.  Because each pair is forced by i7 (and all
//  are cleared by i11), the array holds no state beyond one i7 transition;
//  it stays a relaxation rather than flip-flops so that transition matches.
//
//  Inferred pin roles:
//      i1  MO pixel valid / run-continue      i2..i5  /MPX0../MPX3 (active low)
//      i6  MPR2, the MO "special" bit          i7  line-buffer A/B phase
//      i8  MO write enable                     i9  second enable (o13 only)
//      i11 global blank / reset
//      o12 phase compare  o13 line-buffer strobe  o14..o17 stain state
//      o18 stain set = NOT(MPX1 & MPR2)        o19 stain clear = NOT(MPX2 & MPR2)
//  How the stain state reaches the colour-RAM address is decided in
//  batman_mixer.sv, not here.
//============================================================================

module batman_gal_11d (
	input  logic clk,              // clk_sys, the relaxation step (not a board net)
	input  logic reset,            // synchronous, for simulation (the GAL has no reset)
	input  logic p1,               // pin 1  run-continue enable
	input  logic p2, p3, p4, p5,   // pins 2-5 /MPX0../MPX3, MO pixel, active low
	input  logic p6,               // pin 6  MPR2, the MO "special" bit
	input  logic p7,               // pin 7  line-buffer A/B phase
	input  logic p8,               // pin 8  MO write enable
	input  logic p9,               // pin 9  second enable, o13 only
	input  logic p11,              // pin 11 global blank / reset
	output logic p12,              // pin 12 phase compare, no feedback
	output logic p13,              // pin 13 combined line-buffer strobe
	output logic p14, p15,         // pins 14,15 latch pair A
	output logic p16, p17,         // pins 16,17 latch pair B
	output logic p18,              // pin 18 stain set
	output logic p19               // pin 19 stain clear, no feedback
);

	// ---- the array's input lines, by pin ---------------------------------
	wire i1 = p1, i2 = p2, i3 = p3, i4 = p4, i5 = p5;
	wire i6 = p6, i7 = p7, i8 = p8, i9 = p9, i11 = p11;

	// ---- the latch state: the sums of o14..o17 ---------------------------
	logic s14, s15, s16, s17;

	// The hold terms `i1 & /iN & i8 & /i11 & <pair>` for N = 2..5 combine to
	// `i1 & i8 & /i11 & (MO pixel not transparent)`.
	wire mo_opaque = ~i2 | ~i3 | ~i4 | ~i5;      // (/i2 + /i3 + /i4 + /i5)

	// The two set-term pen decodes (the MO pixel is active low):
	//   pen1  : /i2 & i3 & i4 & i5  -> MPX3:0 == 1
	//   penb1 : i2 & /i3 & i5       -> MPX0 = 0, MPX1 = 1, MPX3 = 0
	wire set_pen1  = ~i2 &  i3 & i4 & i5 & i6 & i8 & ~i11;
	wire set_penb1 =  i2 & ~i3 &      i5 & i6 & i8 & ~i11;

	wire hold_a = i1 & i8 & ~i11 & mo_opaque;            // o14 / o15 family
	wire hold_b = i1 & i8 & ~i11 & mo_opaque & ~i6;      // o16 / o17 family

	wire n_s14 = ( i7 & ~i11) | set_penb1 | set_pen1 | (hold_a & s15 & s17);
	wire n_s15 = (~i7 & ~i11) | set_penb1 | set_pen1 | (hold_a & s14 & s16);
	wire n_s16 = ( i7 & ~i11) |             set_pen1 | (hold_b & s15 & s17);
	wire n_s17 = (~i7 & ~i11) |             set_pen1 | (hold_b & s14 & s16);

	always_ff @(posedge clk) begin
		if (reset) begin
			s14 <= 1'b0; s15 <= 1'b0; s16 <= 1'b0; s17 <= 1'b0;
		end else begin
			s14 <= n_s14; s15 <= n_s15; s16 <= n_s16; s17 <= n_s17;
		end
	end

	// ---- outputs with no feedback -----------------------------------------
	wire s12 = (i7 & i11) | (~i7 & ~i11);            // XNOR(i7, i11)
	wire s18 = ~i3 & i6;
	wire s19 = ~i4 & i6;

	// ---- /o13: one bank's latch, selected by i7 ----------------------------
	wire s13 = (~i7 & ~i9 & ~i11 & s14)
	         | ( i7 & ~i9 & ~i11 & s15)
	         | (~i1 & ~i9 & ~i11)
	         | (~i8 & ~i9 & ~i11)
	         | ( i2 &  i3 &  i4 & i5 & ~i9 & ~i11);

	// Every output is active low: pin = NOT sum.
	assign p12 = ~s12;
	assign p13 = ~s13;
	assign p14 = ~s14;
	assign p15 = ~s15;
	assign p16 = ~s16;
	assign p17 = ~s17;
	assign p18 = ~s18;
	assign p19 = ~s19;

endmodule
