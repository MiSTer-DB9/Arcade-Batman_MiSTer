`timescale 1ns/1ps
//============================================================================
//  Batman GAL20V8A 136085-1003 at 9C: colour-RAM address bits CRA5..CRA10.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//  Structure follows skullxbo_prio.sv of the Skull & Crossbones MiSTer core
//  (GPL-3.0); see NOTICE.md.
//
//  Equations are the GAL fuse map (registered mode: pin 1 = CLK, pin 13 = /OE,
//  pins 15 and 22 are inputs, outputs active high).  Pin names come from
//  ThunderJaws' equivalent GAL, since the manual lacks the video sheets:
//      CRA10 := CS1
//      CRA9  := CS1 ? PFXS : CS0
//      CRA5..8 := CS1 ? PFX7:4 : CS0 ? MPX7:4 : {0, 0, ALC3:2}
//  The 4-bit alpha colour therefore reaches only colour RAM 0x000-0x03F.  The
//  MO colour bits (from the MO RAM) arrive active high, while 9B gets the MO
//  pixel bits (from the inverted stamp ROM) active low; this is the board's
//  wiring.  Pin 10 is wired on the board but used by no product term.
//============================================================================

module batman_gal_9c (
	input  logic clk,                     // pin 1, the pixel clock (assumed the same
	input  logic ce,                      //   net as 9B pin 1)
	input  logic p2, p3, p4, p5,          // pins 2-5   MPX4..MPX7, MO colour, active high
	input  logic p6, p7, p8, p9,          // pins 6-9   PFX4..PFX7, playfield colour
	input  logic p10,                     // pin 10  wired, but used by no term
	input  logic p11,                     // pin 11  ALC2
	input  logic p13_oe_n,                // pin 13  /OE (grounded on the board)
	input  logic p14,                     // pin 14  ALC3
	input  logic p15,                     // pin 15  CS0, from 9B pin 20
	input  logic p22,                     // pin 22  CS1, from 9B pin 21
	input  logic p23,                     // pin 23  PFXS, which playfield won
	output logic p16, p17, p18, p19,      // pins 16-19 CRA5..CRA8
	output logic p20, p21                 // pins 20,21 CRA9, CRA10
);

	// ---- the array's input lines, by pin ---------------------------------
	wire i2  = p2,  i3  = p3,  i4  = p4,  i5  = p5;
	wire i6  = p6,  i7  = p7,  i8  = p8,  i9  = p9;
	wire i11 = p11, i14 = p14, i15 = p15, i22 = p22, i23 = p23;

	// ---- the six registered outputs --------------------------------------
	logic [5:0] q;      // {rf21, rf20, rf19, rf18, rf17, rf16}

	always_ff @(posedge clk) begin
		if (ce) begin
			q[0] <= (i6 & i22) | (i2 & i15 & ~i22) | (i11 & ~i15 & ~i22);
			q[1] <= (i7 & i22) | (i3 & i15 & ~i22) | (i14 & ~i15 & ~i22);
			q[2] <= (i8 & i22) | (i4 & i15 & ~i22);
			q[3] <= (i9 & i22) | (i5 & i15 & ~i22);
			q[4] <= (i22 & i23) | (i15 & ~i22);
			q[5] <=  i22;
		end
	end

	assign {p21, p20, p19, p18, p17, p16} = p13_oe_n ? 6'bzzzzzz : q;

	// Pin 10 is a real board net referenced by no product term.
	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, p10, 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
