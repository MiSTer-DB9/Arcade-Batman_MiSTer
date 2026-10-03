`timescale 1ns/1ps
//============================================================================
//  Batman - GAL16V8 136085-1039 at 20C on the JSA III audio board.  One GAL
//  with four unrelated jobs: the ADPCM ROM select, the divide-by-3 clock loop,
//  the /IRQ merge, and the master-volume strobe /VOL.  Combinational only.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.  See LICENSE, NOTICE.md.
//
//  Ports are named by pin number; the product terms are transcribed verbatim
//  from the fuse map (complex mode).  Pin 17 is active high, the rest active
//  low.  Pins 9 (VA16) and 11 (/ROMN fed back) are wired but used by no term.
//
//  Pin 18 (/IRQ) is the only tri-state output: its sum is always true, so it
//  drives 0 while pin 1 (4MSIRQ) is high and floats otherwise.  It shares the
//  line with the YM2151's open-drain /IRQ, so it is exported as a low-side
//  driver pair (p18_oe, p18_lo) instead of a 'z'.
//
//  What the outputs mean:
//      /ROMN   = !VA17                     to 17E/19E pin 30 (NC on a 27C010)
//      /ROM0   = !(!OKB1 & !VA17)                              19E
//      /ROM1   = !(!OKB0 & OKB1 & !VA17 | !OKB0 & !OKB1 & VA17) 17E
//      /ROM2   = !(OKB0 & OKB1 & !VA17)                        15E
//      /ROM3   = !(VA17 & (OKB0 | OKB1))                       12E
//      CLK1193 = 3579K XOR 1193K           the divide-by-3 feedback loop
//      /VOL    = !(REST & SA8)             master-volume latch strobe
//  Exactly one /ROMn is low for each {OKB1,OKB0,VA17}.  In bank 0 the upper
//  half comes from 17E (/ROM1); MAME maps this differently.
//
//  The divide-by-3 loop is not used as a clock: an XOR feedback of two clocks
//  is unsafe in an FPGA, so batman_sound uses the 1.193182 MHz clock enable
//  (clk_sys/48) instead.  p17 is kept only as a diagnostic.
//============================================================================

module batman_gal_20c (
	input  logic p1,       // <4MSIRQ>  also the pin-18 output enable
	input  logic p2,       // <REST>
	input  logic p3,       // <SA8>
	input  logic p4,       // <3579K>   level model of the clock net
	input  logic p5,       // <1193K>   level model of the clock net
	input  logic p6,       // <OKB0>
	input  logic p7,       // <OKB1>
	input  logic p8,       // <VA17>
	input  logic p9,       // <VA16>    wired, used by no equation
	input  logic p11,      // </ROMN>   pin-12 feedback, used by no equation
	output logic p12,      // </ROMN>
	output logic p13,      // </ROM0>
	output logic p14,      // </ROM1>
	output logic p15,      // </ROM2>
	output logic p16,      // </ROM3>
	output logic p17,      // <CLK1193> pin is active high
	output logic p18_oe,   // </IRQ>    1 = the pin is driving
	output logic p18_lo,   // </IRQ>    level driven while p18_oe (always 0)
	output logic p19       // </VOL>
);

	// ---- the array's input lines, by pin -----------------------------------
	wire i1 = p1, i2 = p2, i3 = p3, i4 = p4, i5 = p5;
	wire i6 = p6, i7 = p7, i8 = p8;

	// ---- the sums, verbatim from the fuse map --------------------------------
	wire n_o12 = i8;
	wire n_o13 = ~i7 & ~i8;
	wire n_o14 = ( ~i6 &  i7 & ~i8 ) | ( ~i6 & ~i7 &  i8 );
	wire n_o15 = (  i6 &  i7 & ~i8 );
	wire n_o16 = (  i6 &  i8 ) | ( i7 & i8 );
	wire o17   = ( i4 & ~i5 ) | ( ~i4 & i5 );
	wire n_o18 = 1'b1;                       // empty sum in the fuse map = always true
	wire n_o19 = i2 & i3;

	// ---- the pins -----------------------------------------------------------
	assign p12 = ~n_o12;
	assign p13 = ~n_o13;
	assign p14 = ~n_o14;
	assign p15 = ~n_o15;
	assign p16 = ~n_o16;
	assign p17 =  o17;
	assign p19 = ~n_o19;

	// Pin 18: active low, output enable = pin 1; written as ~n_o18 to follow
	// the fuse map rather than as a literal 0.
	assign p18_oe = i1;
	assign p18_lo = ~n_o18;

	// Pins 9 and 11 are wired on the board but reach no product term.
	wire _unused_20c = &{ 1'b0, p9, p11 };

endmodule
