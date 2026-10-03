`timescale 1ns/1ps
//============================================================================
//  Batman interrupts: the LS08 IPL encoder at 10K and the LS20 /VPA gate at 7D
//  (from the schematic, page 44).
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.  Structure follows the Skull &
//  Crossbones MiSTer core (GPL-3.0); see NOTICE.md.
//
//  /IPL2 = /VINT AND /AUDIRQ, /IPL1 = /AUDIRQ, /IPL0 tied high, so only levels
//  0, 4 (VAD scanline IRQ) and 6 (sound; masks the VAD) can occur.  Both
//  requests are levels held by their sources, so there is no latch here:
//  /VINT is acked by a VAD register write, /AUDIRQ by reading the sound byte.
//  There is no VBLANK interrupt.  /VPA = NAND(BAS, FC0, FC1, FC2), so every
//  interrupt is autovectored (level 4 -> vector 0x70, level 6 -> 0x78).
//  Purely combinational.
//============================================================================

module batman_irq
(
	// ---- the two request lines, both ACTIVE LOW levels ----
	input  logic       vint_n,     // VAD scanline IRQ, 10K LS08 pin 4
	input  logic       audirq_n,   // from the JSA III, 10K LS08 pin 5

	// ---- the 68000's bus state, for the LS20 ----
	input  logic       bas,        // ACTIVE HIGH copy of /AS
	input  logic [2:0] fc,         // FC2, FC1, FC0

	output logic [2:0] ipl,        // {/IPL2, /IPL1, /IPL0}, ACTIVE LOW
	output logic       vpa_n       // 7D LS20 pin 6 -> 68000 pin 21
);

	// ---------------- 10K LS08 + the two direct wires ---------------------
	assign ipl[2] = vint_n & audirq_n;    // pin 6
	assign ipl[1] = audirq_n;             // a direct wire to pin 24
	assign ipl[0] = 1'b1;                 // pin 25 is tied to +5 V

	// ---------------- 7D LS20 ---------------------------------------------
	assign vpa_n = ~(bas & fc[0] & fc[1] & fc[2]);

endmodule
