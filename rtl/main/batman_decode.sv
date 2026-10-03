`timescale 1ns/1ps
//============================================================================
//  Batman main-board address decode: GAL 136085-1002 at 9L, the 74F138
//  device decoder at 5/6K and the 74LS138 I/O-strobe decoder at 1P/R
//  (from the schematic, pages 42 and 44).  Purely combinational.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.  Structure follows the Skull &
//  Crossbones MiSTer core (GPL-3.0); see NOTICE.md.
//
//  The F138 is enabled by AS & (A20 | A21), so its eight 128 KB windows appear
//  at 0x1xxxxx, 0x2xxxxx and 0x3xxxxx; only the wait states differ between
//  the copies.  The LS138 has no R/W input, so every I/O strobe fires on reads
//  as well as writes (e.g. a read of the latch address clocks the LS273 with
//  the floating bus).  During an interrupt acknowledge the address looks like
//  0x3FFFFx and /VRAM asserts; batman_dtack keeps /DTACK off in that cycle.
//============================================================================

module batman_decode
(
	// ---- the 68000 side ----
	input  logic        as,        // ACTIVE HIGH copy of /AS  (= BAS, 12M LS04)
	input  logic [21:1] a,         // A21..A1.  A22/A23 are not connected on the board
	input  logic        vdtack_n,  // /VDTACK from the VAD, 9L pin 9

	// ---- GAL 9L outputs (not qualified by /AS) ----
	output logic        rom0_n,    // 0x000000-0x03FFFF  10R + 7R
	output logic        rom1_n,    // 0x040000-0x07FFFF  9/10R + 6R
	output logic        rom2_n,    // 0x080000-0x0BFFFF  9R + 5R
	output logic        rom3_n,    // same equation as rom2_n (sockets 8R/4R empty)
	output logic        wait_n,    // /WAIT
	output logic        wait2_n,   // /WAIT2
	output logic        vrwait_n,  // /VRWAIT
	output logic        ioen_n,    // 9L pin 14 -> F138 5/6K /G2A + /G2B

	// ---- F138 5/6K, the device block (A19:A17 inside A20|A21) ----
	output logic        com_n,     // Y0 work RAM        +0x00000
	output logic        eeprom_n,  // Y1 28C16 at 12R    +0x20000
	output logic        f138_y2_n, // Y2 no net          +0x40000
	output logic        cio_n,     // Y3 I/O block       +0x60000
	output logic        f138_y4_n, // Y4 no net          +0x80000
	output logic        wdog_n,    // Y5 watchdog reload +0xA0000
	output logic        f138_y6_n, // Y6 no net          +0xC0000
	output logic        vram_n,    // Y7 the video side  +0xE0000

	// ---- LS138 1P/R, the I/O strobes (MA6:MA4 inside /CIO) ----
	output logic        plsws_n,   // Y0 +0x00  player switches   (/OE of 1P, 2P)
	output logic        status_n,  // Y1 +0x10  status word       (/OE of 2S)
	output logic        ls138_y2_n,// Y2 +0x20  no net
	output logic        scomrd_n,  // Y3 +0x30  AUDIO pin 4
	output logic        scomwr_n,  // Y4 +0x40  AUDIO pin 5
	output logic        latch_n,   // Y5 +0x50  LS273 1S clock
	output logic        unlock_n,  // Y6 +0x60  EEPROM unlock flop /PRE
	output logic        ls138_y7_n // Y7 +0x70  no net
);

	// =====================================================================
	//  9L: GAL16V8A 136085-1002, in its own pin numbers
	// =====================================================================
	batman_gal_9l u_9l (
		.p1  (as),          // BAS
		.p2  (a[21]),
		.p3  (a[20]),
		.p4  (a[19]),
		.p5  (a[18]),
		.p6  (a[17]),
		.p7  (a[16]),       // reaches the array, used by no product term
		.p8  (a[15]),       // likewise
		.p9  (vdtack_n),
		.p11 (~as),         // /AS, the complement of BAS, as the board wires it

		.p12 (wait2_n),
		.p13 (wait_n),
		.p14 (ioen_n),
		.p15 (vrwait_n),
		.p16 (rom3_n),
		.p17 (rom2_n),
		.p18 (rom1_n),
		.p19 (rom0_n)
	);

	// =====================================================================
	//  5/6K: 74F138, the device block
	// =====================================================================
	// G1 = +5 V, /G2A = /G2B = 9L pin 14, so the part is enabled exactly when
	// the GAL says AS & (A20 | A21).
	wire [2:0] f138_sel = {a[19], a[18], a[17]};
	logic [7:0] f138_y;

	always_comb begin
		f138_y = 8'hFF;                       // every output high when disabled
		if (!ioen_n) f138_y[f138_sel] = 1'b0;
	end

	assign com_n     = f138_y[0];
	assign eeprom_n  = f138_y[1];
	assign f138_y2_n = f138_y[2];
	assign cio_n     = f138_y[3];
	assign f138_y4_n = f138_y[4];
	assign wdog_n    = f138_y[5];
	assign f138_y6_n = f138_y[6];
	assign vram_n    = f138_y[7];

	// =====================================================================
	//  1P/R: 74LS138, the I/O strobes
	// =====================================================================
	// Only MA6..MA4 are decoded, so every strobe repeats every 0x80 bytes
	// through the 128 KB /CIO window.  MA1 selects the LS257 input muxes.
	wire [2:0] ls138_sel = {a[6], a[5], a[4]};
	logic [7:0] ls138_y;

	always_comb begin
		ls138_y = 8'hFF;
		if (as && !cio_n) ls138_y[ls138_sel] = 1'b0;
	end

	assign plsws_n    = ls138_y[0];
	assign status_n   = ls138_y[1];
	assign ls138_y2_n = ls138_y[2];
	assign scomrd_n   = ls138_y[3];
	assign scomwr_n   = ls138_y[4];
	assign latch_n    = ls138_y[5];
	assign unlock_n   = ls138_y[6];
	assign ls138_y7_n = ls138_y[7];

	// The remaining address bits are not decode inputs here.
	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused_decode = &{1'b0, a[14:7], a[3:1], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
