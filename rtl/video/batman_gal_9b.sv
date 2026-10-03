`timescale 1ns/1ps
//============================================================================
//  Batman GAL20V8A 136085-1004 at 9B: colour-RAM address bits CRA1..CRA4 and
//  the layer-select pair CS0 / CS1.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//  Structure follows skullxbo_prio.sv of the Skull & Crossbones MiSTer core
//  (GPL-3.0); see NOTICE.md.
//
//  Equations are the GAL fuse map (registered mode: pin 1 = CLK, pin 13 = /OE,
//  pins 15 and 22 are inputs, outputs active high).  The manual lacks the video
//  sheets, so the pin names come from ThunderJaws' equivalent GAL.  Meaning:
//      CS1 = alpha transparent & (PF/M | MO transparent)     -> playfield
//      CS0 = alpha transparent & !PF/M & MO opaque           -> motion object
//      neither                                               -> alphanumerics
//      CRA1..4 := CS1 ? PFX3:0 : CS0 ? MPX3:0 : {ALC1:0, APIX1:0}
//  "Alpha transparent" is !APIX0 & !APIX1 & !ALBG: an opaque alpha pixel always
//  wins, with no priority compare.  The MO pixel bits arrive active low (the
//  stamp ROM is stored inverted), unlike the MO colour bits at 9C; this is the
//  board's wiring, not an error.
//============================================================================

module batman_gal_9b (
	input  logic clk,                // pin 1, the pixel clock (assumed the same net
	input  logic ce,                 //   as 9C pin 1); one `ce` pulse = one pixel
	input  logic p2, p3, p4, p5,     // pins 2-5   /MPX0../MPX3, MO pixel, active low
	input  logic p6, p7, p8, p9,     // pins 6-9   PFX0..PFX3, playfield pixel
	input  logic p10, p11,           // pins 10,11 APIX0, APIX1, alpha pixel
	input  logic p13_oe_n,           // pin 13  /OE for pins 16..19 (grounded on the board)
	input  logic p14, p15,           // pins 14,15 ALC1, ALC0, alpha colour
	input  logic p22,                // pin 22  ALBG, alpha opaque flag
	input  logic p23,                // pin 23  PF/M, from 9D pin 17
	output logic p16, p17, p18, p19, // pins 16-19 CRA1..CRA4
	output logic p20, p21            // pins 20,21 CS0, CS1, to 9C pins 15, 22
);

	// ---- the array's input lines, by pin ---------------------------------
	wire i2  = p2,  i3  = p3,  i4  = p4,  i5  = p5;
	wire i6  = p6,  i7  = p7,  i8  = p8,  i9  = p9;
	wire i10 = p10, i11 = p11, i14 = p14, i15 = p15;
	wire i22 = p22, i23 = p23;

	// ---- the two combinatorial outputs -----------------------------------
	// `gate` is the /i10 & /i11 & /i22 factor shared by every product term.
	wire gate = ~i10 & ~i11 & ~i22;

	wire sum20 = (~i2 & gate & ~i23)
	           | (~i3 & gate & ~i23)
	           | (~i4 & gate & ~i23)
	           | (~i5 & gate & ~i23);

	wire sum21 = (gate & i23)
	           | (i2 & i3 & i4 & i5 & gate);

	// Active-high outputs: pin = sum.
	wire o20 = sum20;
	wire o21 = sum21;
	assign p20 = o20;
	assign p21 = o21;

	// ---- the four registered outputs ------------------------------------
	// `o20` / `o21` in these terms are the pin values, equal to the sums above.
	logic [3:0] q;     // {rf19, rf18, rf17, rf16}

	always_ff @(posedge clk) begin
		if (ce) begin
			q[0] <= (i6 & o21) | (~i2 & o20 & ~o21) | (i10 & ~o20 & ~o21);
			q[1] <= (i7 & o21) | (~i3 & o20 & ~o21) | (i11 & ~o20 & ~o21);
			q[2] <= (i8 & o21) | (~i4 & o20 & ~o21) | (i15 & ~o20 & ~o21);
			q[3] <= (i9 & o21) | (~i5 & o20 & ~o21) | (i14 & ~o20 & ~o21);
		end
	end

	// /OE (pin 13) gates the pins, not the registers.
	assign {p19, p18, p17, p16} = p13_oe_n ? 4'bzzzz : q;

endmodule
