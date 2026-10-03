`timescale 1ns/1ps
//============================================================================
//  Batman (Atari Games, 1990/91) - JSA III audio board A048974-01: the latches
//  and port on the 6502's I/O strobes: LS273 10A control latch (/WRIO $2A04),
//  LS174 8A mixer latch (/MIX $2A06), LS273 7C master-volume latch (/VOL $29xx)
//  and LS240 13A status port (/RDIO $2804), plus the coin-counter drivers.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.  See LICENSE, NOTICE.md.
//
//  Module shape follows the Skull & Crossbones core's skullxbo_snd_io.sv
//  (GPL-3.0); the bit maps are the JSA III's own, from the schematic.
//
//  10A (/WRIO):  7 BA13  6 BA12  5 CCTR2  4 CCTR1  3 VFREQ (SS: 0 = /165,
//                1 = /132)  2 /OKIRES  1 OKB0  0 /YAMRES (YM2151 + YM3012 /IC)
//  8A  (/MIX):   5 LPF (adds C33 3300 pF to the YM Sallen-Key)  4 OKB1
//                3:1 YM volume N (gain N/7, N = 0 mutes)  0 SP0 (adds R65 7.5K
//                to the ADPCM level).  Hex flop: bits 7:6 do not exist.
//  7C  (/VOL):   6:0 switch R38 10K, R35 20K, R36 39K, R34 82K, R37 160K,
//                R33 330K, R32 620K into the master-gain stage: the game's
//                master volume, 0 = silent, $7F = full (see batman_snd_mix).
//                Bit 7 is latched but not connected.
//  13A (/RDIO):  inverting buffer, so a closed switch reads 1.
//                7 self-test  6 /AUDFULL (1 = main->sound byte pending)
//                5 /AUDIRQ (1 = sound->main byte pending)  4 self-test again
//                (same node as bit 7)  3 service  2 tilt  1 coin L  0 coin R
//
//  /RESET (a level from the game board) clears these three latches and nothing
//  else.  Out of reset the YM2151/YM3012 and MSM6295 are held in reset, the OKI
//  runs at 7231 Hz (MAME starts at 9039 Hz), ROM bank 0, YM path muted, master
//  volume 0 (silent until the game sets it).
//
//  MAME reads bit 6 with the opposite sense to bit 5; on the board both come
//  from a /Q of 17B through the same inverter, so they match.  The 6502 never
//  polls bit 6.  mame_polarity reproduces MAME's byte for comparison and is
//  tied to 0 in the core.
//
//  Coin counters: R18 = 0 ohm bridges the two driver outputs, so on the real
//  board either bit drives both counters (MAME has two independent ones).
//  Both bits are exported, and cctr_wired_or is the node the board has.
//============================================================================

module batman_snd_io
(
	input  logic        clk,

	// ---- /RESET: JAUD pin 1, a level.  10A /CLR, 8A /MR, 7C /CLR ----
	input  logic        reset_n,

	// ---- the three write strobes (each one `ce_1m79` wide) ----
	input  logic        wrio_stb,      // /WRIO ($2A04) -> 10A LS273
	input  logic        mix_stb,       // /MIX  ($2A06) -> 8A  LS174
	input  logic        vol_stb,       // /VOL  ($29xx) -> 7C  LS273
	input  logic  [7:0] sd,            // SD7:0 at that access (the strobes
	                                   // ignore the bus direction)

	// ---- LS240 13A sources (all logical "asserted" = 1) ----
	input  logic        self_test,     // the shared /SELFTEST node, 1 = ON
	input  logic        service,       // JAMMA-R  /SERVICE
	input  logic        tilt,          // JAMMA-S  /TILT
	input  logic        coin_l,        // JAMMA-16 /COINL
	input  logic        coin_r,        // JAMMA-T  /COINR
	input  logic        audfull,       // 17B/1: main->sound byte pending
	input  logic        audirq,        // 17B/2: sound->main byte pending
	input  logic        mame_polarity, // test only: MAME's bit-6 sense

	// ---- LS273 10A outputs ----
	output logic  [1:0] bank,          // {BA13, BA12} -> 17C pins 4, 3
	output logic        cctr2,         // bit 5 -> Q1 -> /CCNTRR
	output logic        cctr1,         // bit 4 -> Q2 -> /CCNTRL
	output logic        cctr_wired_or, // the R18 = 0 ohm node
	output logic        vfreq,         // MSM6295 pin 7 SS   (0 from reset)
	output logic        okires_n,      // MSM6295 pin 8, active low, a level
	output logic        okb0,          // 20C pin 6
	output logic        yamres_n,      // YM2151 /IC + YM3012 /IC, active low

	// ---- LS174 8A outputs ----
	output logic        lpf,           // 4C-A / C33
	output logic        okb1,          // 20C pin 7
	output logic  [2:0] ym_vol,        // {YM2,YM1,YM0}, N = 0..7, 0 = mute
	output logic        sp0,           // 3D-A / R65

	// ---- LS273 7C output ----
	output logic  [6:0] vol,           // the seven 4066 switches

	// ---- the assembled $2804 byte ----
	output logic  [7:0] rdio_data
);

	// ---- LS273 10A ---------------------------------------------------------
	// /CLR is asynchronous on the part; a synchronous clear is equivalent here
	// because /RESET is held for at least microseconds.
	always_ff @(posedge clk) begin
		if (!reset_n) begin
			bank     <= 2'd0;
			cctr2    <= 1'b0;
			cctr1    <= 1'b0;
			vfreq    <= 1'b0;   // SS = 0 -> /165 -> 7231 Hz
			okires_n <= 1'b0;   // the MSM6295 is held in reset from power-on
			okb0     <= 1'b0;
			yamres_n <= 1'b0;   // and so are the YM2151 and the YM3012
		end else if (wrio_stb) begin
			bank     <= sd[7:6];
			cctr2    <= sd[5];
			cctr1    <= sd[4];
			vfreq    <= sd[3];
			okires_n <= sd[2];
			okb0     <= sd[1];
			yamres_n <= sd[0];
		end
	end

	// R18 = 0 ohm ties /CCNTRR and /CCNTRL into one node.
	assign cctr_wired_or = cctr1 | cctr2;

	// ---- LS174 8A ----------------------------------------------------------
	always_ff @(posedge clk) begin
		if (!reset_n) begin
			lpf    <= 1'b0;     // the HIGH corner, 8941 Hz
			okb1   <= 1'b0;
			ym_vol <= 3'd0;     // true mute: no 4066 section closed
			sp0    <= 1'b0;     // the low ADPCM gain step
		end else if (mix_stb) begin
			lpf    <= sd[5];
			okb1   <= sd[4];
			ym_vol <= sd[3:1];
			sp0    <= sd[0];
		end
	end

	// ---- LS273 7C ----------------------------------------------------------
	// Eight flops, seven wired.  Bit 7 reaches nothing, so it is not modelled.
	always_ff @(posedge clk) begin
		if (!reset_n)        vol <= 7'd0;   // master volume 0, silent
		else if (vol_stb)    vol <= sd[6:0];
	end

	// ---- LS240 13A ---------------------------------------------------------
	wire d6 = mame_polarity ? ~audfull : audfull;      // MAME's inverted bit 6
	assign rdio_data = { self_test, d6, audirq, self_test,
	                     service, tilt, coin_l, coin_r };

endmodule
