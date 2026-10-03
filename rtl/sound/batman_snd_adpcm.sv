`timescale 1ns/1ps
//============================================================================
//  Batman (Atari Games, 1990/91) - JSA III audio board A048974-01: the OKI
//  MSM6295 at 10E and its four 27C010 sample ROMs at 19E / 17E / 15E / 12E,
//  selected through GAL 136085-1039 at 20C.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.  See LICENSE, NOTICE.md.
//
//  The chip itself is batman_oki.sv, carried over from the Skull & Crossbones
//  core's skullxbo_oki.sv (GPL-3.0), itself derived from the Klax core's
//  klax_oki6295.v (GPL-2.0-or-later).  This wrapper adds what lies outside it:
//    1. A 512 KB sample set: VA17 goes only to GAL 20C, which combines it with
//       the bank bits {OKB1,OKB0} to pick one of four 128 KB ROMs.
//    2. SS = VFREQ, the software sample-rate select; it powers up at 0, i.e.
//       divide-by-165 = 7231 Hz (MAME starts at 9039 Hz instead).
//    3. /CS (pin 4) is tied to GND, so /RDV and /WRV alone time each access.
//
//  Bank table (from the GAL fuse map):
//   OKB1:OKB0 | VA17 = 0              | VA17 = 1
//      0 0    | /ROM0 19E             | /ROM1 17E   (MAME uses 12E here)
//      0 1    | /ROM0 19E             | /ROM3 12E
//      1 0    | /ROM1 17E             | /ROM3 12E
//      1 1    | /ROM2 15E             | /ROM3 12E
//
//  SDRAM: the ROMs are laid out as MAME's jsa:oki1 region (19E, 17E, 15E, 12E
//  at $00000/$20000/$40000/$60000), so oki_addr = {rom_sel, VA16:VA0} is an
//  offset inside that region; the arbiter adds the region base.  The chip
//  tolerates any read latency.
//
//  /ROMN drives 17E/19E pin 30 (NC on a 27C010; the straps R60/R61 that would
//  make it A17 are not fitted) and /ROM3 also drives their pin 31 (/PGM), so
//  /ROM3 must never be low while 17E or 19E is selected.  Checked below.
//============================================================================

module batman_snd_adpcm
(
	input  logic        clk,
	input  logic        ce_1m19,       // XT (pin 5) = 1.193182 MHz
	input  logic        okires_n,      // pin 8  /RESET  <- /WRIO bit 2, a level
	input  logic        vfreq,         // pin 7  SS      <- /WRIO bit 3

	// ---- the 6502 host port (/CS is tied low; these strobes time accesses)
	input  logic        wr_stb,        // pin 3 /WR = /WRV ($2A00)
	input  logic  [7:0] wr_data,       // I0..I7 = SD0..SD7
	input  logic        rd_stb,        // pin 2 /RD = /RDV ($2800)
	output logic  [7:0] rd_data,       // status byte, $F0 | playing voices

	// ---- GAL 20C: this module publishes VA17/VA16 and consumes /ROM0../ROM3
	output logic        va17,          // pin 35 -> 20C pin 8 (never to a ROM)
	output logic        va16,          // pin 34 -> 20C pin 9 (spare) and the ROMs
	input  logic  [3:0] rom_n,         // {/ROM3,/ROM2,/ROM1,/ROM0}, active low
	input  logic        romn_n,        // /ROMN -> pin 30 of 17E/19E (NC)

	// ---- the 512 KB sample region in SDRAM, as a byte client ----
	output logic        oki_req,
	output logic [18:0] oki_addr,      // {rom_sel, VA16:VA0}
	input  logic        oki_ack,
	input  logic  [7:0] oki_data,

	output logic signed [15:0] audio   // DAO (pin 36), to the analogue section
);

	// ---- the MSM6295 itself -------------------------------------------------
	wire [17:0] va;                    // A0..A17
	batman_oki u_oki (
		.clk(clk), .ce_1m19(ce_1m19), .okires_n(okires_n), .vfreq(vfreq),
		.wr_stb(wr_stb), .wr_data(wr_data), .rd_stb(rd_stb), .rd_data(rd_data),
		.oki_req(oki_req), .oki_addr(va), .oki_ack(oki_ack), .oki_data(oki_data),
		.audio(audio) );

	assign va17 = va[17];
	assign va16 = va[16];

	// ---- the GAL's four selects -> a 2-bit region index ---------------------
	// Exactly one of rom_n is low; the priority chain only gives the
	// impossible all-high case a defined result.
	wire [1:0] rom_sel = ~rom_n[0] ? 2'd0     // /ROM0 -> 19E  $00000
	                   : ~rom_n[1] ? 2'd1     // /ROM1 -> 17E  $20000
	                   : ~rom_n[2] ? 2'd2     // /ROM2 -> 15E  $40000
	                   :             2'd3;    // /ROM3 -> 12E  $60000

	assign oki_addr = { rom_sel, va[16:0] };

	// Simulation-only check: the selects are one-hot, and /ROM3 (= /PGM on
	// 17E/19E) is never low while 17E or 19E is enabled.
`ifndef ALTERA_RESERVED_QIS
	// verilator lint_off UNUSEDSIGNAL
	wire [2:0] rom_low_count = {2'b00, ~rom_n[0]} + {2'b00, ~rom_n[1]}
	                         + {2'b00, ~rom_n[2]} + {2'b00, ~rom_n[3]};
	wire rom_onehot_bad = (rom_low_count != 3'd1);
	wire rom_pgm_bad    = ~rom_n[3] & (~rom_n[0] | ~rom_n[1]);
	always @(posedge clk) if (!$isunknown(rom_n)) begin
		if (rom_onehot_bad)
			$display("%t batman_snd_adpcm: /ROM0..3 = %b is not one-hot-low", $time, rom_n);
		if (rom_pgm_bad)
			$display("%t batman_snd_adpcm: /PGM low while 19E/17E selected", $time);
	end
	// verilator lint_on UNUSEDSIGNAL
`endif

	wire _unused_adpcm = &{ 1'b0, romn_n };

endmodule
