`timescale 1ns/1ps
//============================================================================
//  Batman - GAL16V8 136085-1038 at 17C: the 6502 address decoder of the JSA III
//  audio board (A048974-01).  Pure combinational logic, no clock or state.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.  See LICENSE, NOTICE.md.
//
//  One module per GAL: ports are named by pin number and the product terms are
//  transcribed verbatim from the fuse map (complex mode; pins 12 and 19 have no
//  feedback).  Signal names in <...> come from the schematic.  Pins 16 and 17
//  are active high, the other six active low.  /SRD's fourth term uses the
//  pin-17 feedback, as the silicon does.  SA10 is not a GAL input; it goes to
//  the LS138 at 18C instead.
//
//  What the outputs mean:
//      /RAM = !(SA13 | SA14 | SA15)                     $0000-$1FFF
//      REST =  O2 & $2800-$2FFF                         enables the LS138 18C
//      /YAM = !($2000-$27FF)                            YM2151 chip select
//      /ROM = !(read & >= $3000)
//      /SWR = !(write & O2 & (RAM | YM2151))
//      /SRD =  read strobe; its three I/O-page terms are inert on this board
//              (the LS138 is enabled by REST, not /SRD), left over from JSA I
//      A12B/A13B = BA12/BA13 in the bank window $3000-$3FFF, else SA12/SA13
//============================================================================

module batman_gal_17c (
	input  logic p1,       // <SR/W>   1 = read
	input  logic p2,       // <O2>     6502 11C pin 39
	input  logic p3,       // <BA12>   10A LS273 bit 6
	input  logic p4,       // <BA13>   10A LS273 bit 7
	input  logic p5,       // <SA9>
	input  logic p6,       // <SA11>
	input  logic p7,       // <SA12>
	input  logic p8,       // <SA13>
	input  logic p9,       // <SA14>
	input  logic p11,      // <SA15>
	output logic p12,      // </SRD>
	output logic p13,      // </SWR>
	output logic p14,      // <A12B>   to program ROM 12C A12
	output logic p15,      // <A13B>   to program ROM 12C A13
	output logic p16,      // </RAM>   pin is active high (to 15C /CS1)
	output logic p17,      // <REST>   pin is active high (to 18C G1)
	output logic p18,      // </YAM>
	output logic p19       // </ROM>
);

	// ---- the array's input lines, by pin -----------------------------------
	wire i1 = p1, i2 = p2, i3 = p3, i4  = p4,  i5 = p5;
	wire i6 = p6, i7 = p7, i8 = p8, i9  = p9, i11 = p11;

	// ---- the sums, verbatim from the fuse map --------------------------------
	wire n_o12_a =           ~i2 &  i6 & ~i7 & i8 & ~i9 & ~i11;
	wire n_o12_b = ~i1 & ~i5 &      i6 & ~i7 & i8 & ~i9 & ~i11;
	wire n_o12_c =  i1 &  i5 &      i6 & ~i7 & i8 & ~i9 & ~i11;
	wire o17     =  i2 &            i6 & ~i7 & i8 & ~i9 & ~i11;   // the pin-17 sum
	wire n_o12_d =  i1 &  i2 & ~o17;                              // pin-17 feedback
	wire n_o12   = n_o12_a | n_o12_b | n_o12_c | n_o12_d;

	wire n_o13   = ( ~i1 & i2 & ~i6 & ~i7 & i8 & ~i9 & ~i11 )
	             | ( ~i1 & i2 &             ~i8 & ~i9 & ~i11 );

	wire n_o14   = ~i7 | ( ~i3 & i7 & i8 & ~i9 & ~i11 );
	wire n_o15   = ~i8 | ( ~i4 & i7 & i8 & ~i9 & ~i11 );

	wire o16     = i8 | i9 | i11;

	wire n_o18   = ~i6 & ~i7 & i8 & ~i9 & ~i11;

	wire n_o19   = ( i1 & i7 & i8 ) | ( i1 & i9 ) | ( i1 & i11 );

	// ---- the pins: active low = one inversion, active high = none
	assign p12 = ~n_o12;
	assign p13 = ~n_o13;
	assign p14 = ~n_o14;
	assign p15 = ~n_o15;
	assign p16 =  o16;
	assign p17 =  o17;
	assign p18 = ~n_o18;
	assign p19 = ~n_o19;

endmodule
