`timescale 1ns/1ps
//============================================================================
//  Batman GAL16V8A 136085-1002 at 9L (label B_MAIN): the 68000 address
//  decoder.  Equations from the GAL fuse map; pin names from the schematic,
//  page 44.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.  Structure follows the GAL
//  transcriptions of the Skull & Crossbones MiSTer core (GPL-3.0); see
//  NOTICE.md.
//
//  Simple mode: pins 1 and 11 are ordinary inputs, every output is
//  combinational and active low (pin NN goes low when its sum is true).
//    /ROM0..3  256 KB banks on A19:A18 with A21 = A20 = 0.  /ROM2 and /ROM3
//              have the same equation (9R/5R and the empty 8R/4R sockets).
//    pin 14    AS & (A20 | A21), the F138 enable.  It uses both BAS and /AS,
//              which stretches the enable slightly past /AS rising and gives
//              the LS273 at 1S its clock edge inside the data-hold window.
//    /WAIT     the ROM megabyte plus the video window A21:A17 = 11111.
//    /WAIT2    all of 0x1xxxxx.
//    /VRWAIT   the video window while /VDTACK is still high.
//  Only pin 14 is qualified by /AS; the rest are pure address decodes.
//============================================================================

module batman_gal_9l
(
	input  logic p1,     // BAS
	input  logic p2,     // A21
	input  logic p3,     // A20
	input  logic p4,     // A19
	input  logic p5,     // A18
	input  logic p6,     // A17
	input  logic p7,     // A16, used by no product term
	input  logic p8,     // A15, used by no product term
	input  logic p9,     // /VDTACK
	input  logic p11,    // /AS

	output logic p12,    // /WAIT2
	output logic p13,    // /WAIT
	output logic p14,    // -> F138 5/6K /G2A + /G2B ("/IOEN")
	output logic p15,    // /VRWAIT
	output logic p16,    // /ROM3
	output logic p17,    // /ROM2
	output logic p18,    // /ROM1
	output logic p19     // /ROM0
);

	// ---- the array's input lines, by pin --------------------------------
	wire i1 = p1, i2 = p2, i3 = p3, i4 = p4, i5 = p5, i6 = p6;
	wire i9 = p9, i11 = p11;

	// i7 (A16) and i8 (A15) reach the array but appear in no product term.
	/* verilator lint_off UNUSEDSIGNAL */
	wire i7 = p7, i8 = p8;
	/* verilator lint_on UNUSEDSIGNAL */

	// ---- the sums, as in the fuse map -----------------------------------
	wire s12 = ~i2 & i3;
	wire s13 = ( i2 &  i3 & i4 & i5 & i6) | (~i2 & ~i3);
	wire s14 = ( i1 &  i3) | ( i3 & ~i11) | ( i1 & i2) | ( i2 & ~i11);
	wire s15 =   i2 &  i3 & i4 & i5 & i6 & i9;
	wire s16 =  ~i2 & ~i3 & i4 & ~i5;
	wire s17 =  ~i2 & ~i3 & i4 & ~i5;
	wire s18 =  ~i2 & ~i3 & ~i4 & i5;
	wire s19 =  ~i2 & ~i3 & ~i4 & ~i5;

	// ---- ACTIVE LOW outputs: the pin is driven LOW when the sum is true --
	assign p12 = ~s12;
	assign p13 = ~s13;
	assign p14 = ~s14;
	assign p15 = ~s15;
	assign p16 = ~s16;
	assign p17 = ~s17;
	assign p18 = ~s18;
	assign p19 = ~s19;

endmodule
