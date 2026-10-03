`timescale 1ns/1ps
//============================================================================
//  Batman GAL16V8A 136085-1006 at 9D: PF/M (playfield-over-motion-object
//  priority), its complement, and an "MO byte == 0x01" decode.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//  Structure follows skullxbo_prio.sv of the Skull & Crossbones MiSTer core
//  (GPL-3.0); see NOTICE.md.
//
//  Equations are the GAL fuse map (complex mode; pins 1 and 11 are plain
//  inputs; pins 13-16 are inputs).  Pin 17 is active high and pin 18 carries
//  the same sum active low.  The manual lacks the video sheets, so pin names
//  are inferred from ThunderJaws' GAL and MAME.  PF/M reproduces MAME's rule
//  for the selected playfield's priority PFX9:8 against MO priority MPR1:0:
//      3: playfield always wins           2: wins if MPR < 2 and not upper pen
//      1: wins if MPR == 0 and not upper pen   0: never
//  Pins 15/16 are taken as PFX3 and PFXS, so the "upper pen" terms apply only
//  when the foreground playfield is selected, as MAME does.
//  Pin 19 decodes "MO byte == 0x01".  ThunderJaws ORs it into PF/M; Batman does
//  not, and MAME has no such rule, so the mixer leaves pin 19 unconnected.
//============================================================================

module batman_gal_9d (
	input  logic p1, p2, p3, p4,   // pins 1-4  /MPX0../MPX3, MO pixel, active low
	input  logic p5, p6, p7, p8,   // pins 5-8  MPX4..MPX7, MO colour, active high
	input  logic p9,               // pin 9   MPR0, MO priority bit 0
	input  logic p11,              // pin 11  MPR1, MO priority bit 1
	input  logic p13,              // pin 13  PFX9, playfield priority bit 1
	input  logic p14,              // pin 14  PFX8, playfield priority bit 0
	input  logic p15,              // pin 15  PFX3, upper-pen qualifier
	input  logic p16,              // pin 16  PFXS, background-playfield flag
	output logic p12,              // pin 12  unused OLMC, no product term
	output logic p17,              // pin 17  PF/M, to 9B pin 23
	output logic p18,              // pin 18  /PF/M, destination unknown
	output logic p19               // pin 19  /MO1, "MO byte == 1", unconnected
);

	// ---- the array's input lines, by pin ---------------------------------
	wire i1 = p1, i2 = p2, i3 = p3, i4  = p4;
	wire i5 = p5, i6 = p6, i7 = p7, i8  = p8;
	wire i9 = p9, i11 = p11, i13 = p13, i14 = p14, i15 = p15, i16 = p16;

	// ---- the equations ----------------------------------------------------
	wire sum17 = (i13 & i14)
	           | (~i9 & ~i11 & i14 & ~i15 & ~i16)
	           | (~i11 & i13 & ~i15 & ~i16);

	// Pins 17 and 18 carry the same sum; 18 is active low.
	wire sum18 = sum17;

	wire sum19 = ~i1 & i2 & i3 & i4 & ~i5 & ~i6 & ~i7 & ~i8;

	assign p17 =  sum17;     // active high
	assign p18 = ~sum18;     // active low
	assign p19 = ~sum19;     // active low

	// Pin 12 has no equation in the fuse map (the output is not enabled).  The
	// constant is a placeholder; nothing reads it.
	assign p12 = 1'b0;

endmodule
