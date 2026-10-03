`timescale 1ns/1ps
//============================================================================
//  Batman (Atari Games, 1990/91) - JSA III audio board A048974-01: a digital
//  model of the analogue chain.  The 4066 YM volume ladder at 3D, the switched
//  Sallen-Key at 1D-B, the MSM6295 filter chain at 6F with its SP0 gain step,
//  the 1D-C summing mixer and the 7-bit /VOL master volume at 1D-D.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.  See LICENSE, NOTICE.md.
//
//  Structure follows the Skull & Crossbones core's skullxbo_snd_filter.sv
//  (GPL-3.0); the topology and values are the JSA III's (from the schematic).
//
//  YM path:
//    YM3012 CH1/CH2 -> unity buffers 6D-D/6D-A -> 4066 ladder 3D onto YMAUD:
//      YM0 R50/R40 30K, YM1 R44/R41 15K, YM2 R54/R43 7.5K  -> gain N/7, N=0 mute
//      no series coupling capacitor, so no high-pass (unlike the JSA II)
//    1D-A R51 6.2K (constant gain, folded into normalisation)
//    1D-B Sallen-Key R53 = R52 = 12K, C37 2200 pF, C29 1000 pF:
//      LPF = 0: 8941 Hz, Q 0.742;  LPF = 1 adds C33 3300 pF: 4312 Hz, Q 0.358
//      (MAME does not model the LPF bit)
//  ADPCM path (MSM6295 DAO):
//    6F-A unity buffer
//    6F-B Sallen-Key R68/R71 6.8K, C41 1000 pF + C43 6800 pF, C39 0.015 uF,
//      gain 3: 2164 Hz, Q 0.751
//    6F-C R66 10K, C42 6800 pF: 2340 Hz
//    node K R70 2K, C38 0.1 uF, into 6F-D (R63 10K) via R64 15K (SP0 = 0:
//      gain 0.588, 901 Hz) or R64 || R65 7.5K (SP0 = 1: gain 1.429, 1114 Hz)
//    so SP0 is x2.43 at DC and x3.0 above 2 kHz, not MAME's flat x2
//    Not modelled: the C48/R67/C49/R69 bridge (a small extra pole and zero
//    above 3 kHz, where this path is already strongly filtered).
//  Mixer 1D-C: R48 3.3K feedback, ADPCM via R62 15K, YM via R49 33K -> 33 : 15.
//  /VOL 1D-D: R29 5.1K feedback, switched R32..R38 620K..10K.  R39 5.1K is
//    drawn but not fitted on production boards, so gain(D) = sum 5.1K/R_i ~=
//    D/127 (0 mutes, $7F = x1.0135, as MAME).  R39_FITTED = 1 gives the drawn
//    x1.0 .. x2.0135 law.
//
//  The chip full-scale swings are not on the schematic, so each path is
//  normalised to unity at its loudest setting (YM N = 7, ADPCM SP0 = 1) and
//  the two are mixed in the resistor ratio 33 : 15 (weights summing to 65536,
//  so the mix cannot clip before /VOL).  BAL_OKI / BAL_YM allow retuning.
//  Output saturates; clipped is sticky.  The amplifier after AUDOUT is not
//  modelled (the MiSTer volume replaces it).
//
//  All stages run at ce = ce_1m79 = 1.789773 MHz; they are the reconstruction
//  filters for the YM3012 (55.9 kHz) and MSM6295 (7.2 kHz) sample-and-holds.
//      1-pole  k = 1 - exp(-2*pi*fc/fs), Q20      (batman_snd_iir1)
//      2-pole  f = 2*sin(pi*f0/fs), q = 1/Q, Q16  (batman_snd_svf)
//============================================================================

module batman_snd_mix #(
	// R62 15K and R49 33K into R48 3.3K.  Q16, summing to exactly 65536 so two
	// simultaneously full-scale paths cannot clip.
	parameter int BAL_OKI    = 45056,    // 33/48 = 0.6875
	parameter int BAL_YM     = 20480,    // 15/48 = 0.3125
	// Q16 scale applied to the /VOL gain.  65536 = the exact law.
	parameter int VOL_HEADROOM = 65536,
	// Is R39 (5.1K, rail -> 1D-D summing node) fitted?
	//   0 = not fitted (default): gain(D) = sum 5.1K/R_i ~= D/127, 0 .. x1.0135.
	//       JSA III parts lists omit R39, and the game's volume fade-in is only
	//       an even dB ramp with this law.
	//   1 = fitted as drawn on the schematic: x1.0 .. x2.0135.
	parameter bit R39_FITTED = 1'b0
) (
	input  logic        clk,
	input  logic        ce,              // ce_1m79 = 1.7897727 MHz
	input  logic        reset,
	input  logic        bypass,          // 1 = raw unfiltered sum, for comparison

	// ---- LS174 8A ----
	input  logic  [2:0] ym_vol,          // N = 4*YM2 + 2*YM1 + YM0
	input  logic        lpf,             // the 1D-B Sallen-Key switch
	input  logic        sp0,             // the 6F-D gain step
	// ---- LS273 7C ----
	input  logic  [6:0] vol,             // the seven 4066 sections

	// ---- sources ----
	input  logic signed [15:0] ym_ch1,   // YM3012 CH1 -> 6D-D -> the ladder
	input  logic signed [15:0] ym_ch2,   // YM3012 CH2 -> 6D-A -> the ladder
	input  logic signed [15:0] oki_in,   // MSM6295 DAO -> DAD -> 6F-A

	// ---- output.  The board is mono: AUDOUT is the only output ----
	output logic signed [15:0] out,
	output logic        clipped,         // sticky: the saturator fired

	// ---- stage taps, for debugging ----
	output logic signed [15:0] dbg_ym_lad,  // after the N/7 ladder
	output logic signed [15:0] dbg_ym,      // after the Sallen-Key (path out)
	output logic signed [15:0] dbg_oki_s2,  // after the 2164 Hz pole pair
	output logic signed [15:0] dbg_oki_s3,  // after the 2340 Hz RC
	output logic signed [15:0] dbg_oki,     // after node K (path out)
	output logic signed [15:0] dbg_premix   // after the mixer, before the trim
);

	// ========================================================================
	//  Coefficients.  fs = 57272727 / 32 = 1789772.72 Hz.
	// ========================================================================
	// The YM ladder, exactly N/7 (Q16).  No high-pass on this board.
	logic [17:0] g_ym;
	always_comb begin
		case (ym_vol)
			3'd0:    g_ym = 18'd0;        // true mute: no 4066 path closed
			3'd1:    g_ym = 18'd9362;
			3'd2:    g_ym = 18'd18725;
			3'd3:    g_ym = 18'd28087;
			3'd4:    g_ym = 18'd37449;
			3'd5:    g_ym = 18'd46811;
			3'd6:    g_ym = 18'd56174;
			default: g_ym = 18'd65536;
		endcase
	end

	// 1D-B, both states: 8941 Hz / Q 0.742 (LPF = 0), 4312 Hz / Q 0.358 (LPF = 1).
	wire [18:0] f_ym_lp = lpf ? 19'd992    : 19'd2057;
	wire [18:0] q_ym_lp = lpf ? 19'd183061 : 19'd88369;

	// 6F-B: 2164 Hz, Q 0.751 (C41 + C43 = 7800 pF).
	localparam logic [18:0] F_OKI_S2 = 19'd498;
	localparam logic [18:0] Q_OKI_S2 = 19'd87247;
	// 6F-C: 2340 Hz (R66 10K, C42 6800 pF).
	localparam logic [19:0] K_OKI_S3 = 20'd8580;
	// node K pole, moved by SP0: 901 Hz / 1114 Hz.
	wire [19:0] k_oki_k = sp0 ? 20'd4093 : 20'd3311;
	// and the DC gain that moves with it, normalised to the loud step:
	// (10/17)/(10/7) = 7/17 = 0.411765.
	wire [17:0] g_oki   = sp0 ? 18'd65536 : 18'd26985;

	// ========================================================================
	//  YM path - 6D buffers, the 3D ladder, 1D-A, 1D-B
	// ========================================================================
	// The ladder sums both YM3012 channels with equal weight; the >>> 1 is
	// normalisation, so a voice on one channel only is half scale.
	wire signed [16:0] ym_sum = {ym_ch1[15], ym_ch1} + {ym_ch2[15], ym_ch2};
	wire signed [17:0] ym_in  = {{2{ym_sum[16]}}, ym_sum[16:1]};

	// N/7, Q16.  Registered for timing; ce comes every 32 clocks.
	wire signed [35:0] ym_lad_m = ym_in * $signed({1'b0, g_ym});
	logic signed [17:0] ym_lad_r;
	always_ff @(posedge clk) begin
		if (reset) ym_lad_r <= '0;
		else       ym_lad_r <= 18'(ym_lad_m >>> 16);
	end

	wire signed [17:0] ym_path;
	batman_snd_svf u_ym_lp (
		.clk(clk), .ce(ce), .reset(reset), .f(f_ym_lp), .q(q_ym_lp),
		.x(ym_lad_r), .y(ym_path) );

	// ========================================================================
	//  ADPCM path - 6F-A..6F-D
	// ========================================================================
	wire signed [17:0] oki_in18 = {{2{oki_in[15]}}, oki_in};

	wire signed [17:0] oki_s2;
	batman_snd_svf u_oki_s2 (
		.clk(clk), .ce(ce), .reset(reset), .f(F_OKI_S2), .q(Q_OKI_S2),
		.x(oki_in18), .y(oki_s2) );

	wire signed [17:0] oki_s3;
	batman_snd_iir1 #(.HIGHPASS(1'b0)) u_oki_s3 (
		.clk(clk), .ce(ce), .reset(reset), .k(K_OKI_S3), .x(oki_s2), .y(oki_s3) );

	// The SP0 gain and the node-K pole are modelled separately, which gives
	// the step of x2.43 at DC and x3.0 above 2 kHz.
	wire signed [35:0] oki_g_m = oki_s3 * $signed({1'b0, g_oki});
	logic signed [17:0] oki_g_r;
	always_ff @(posedge clk) begin
		if (reset) oki_g_r <= '0;
		else       oki_g_r <= 18'(oki_g_m >>> 16);
	end

	wire signed [17:0] oki_path;
	batman_snd_iir1 #(.HIGHPASS(1'b0)) u_oki_k (
		.clk(clk), .ce(ce), .reset(reset), .k(k_oki_k), .x(oki_g_r), .y(oki_path) );

	// ========================================================================
	//  1D-C, the summing mixer, 33 : 15
	// ========================================================================
	wire signed [35:0] mix_ym  = ym_path  * $signed({1'b0, 18'(BAL_YM)});
	wire signed [35:0] mix_oki = oki_path * $signed({1'b0, 18'(BAL_OKI)});
	logic signed [19:0] mix_r;
	always_ff @(posedge clk) begin
		if (reset) mix_r <= '0;
		else       mix_r <= 20'((mix_ym >>> 16) + (mix_oki >>> 16));
	end

	// ========================================================================
	//  1D-D, the /VOL stage: exact seven-term sum
	// ========================================================================
	//   bit  R       5.1K/R      Q16
	//    0   620 K   0.008226      539
	//    1   330 K   0.015455     1013
	//    2   160 K   0.031875     2089
	//    3    82 K   0.062195     4076
	//    4    39 K   0.130769     8570
	//    5    20 K   0.255000    16712
	//    6    10 K   0.510000    33423
	//   R39 5.1K, if fitted, adds the 65536 base ($7F = x2.0135).  Not fitted
	//   (default): $00 = 0 (mute), $7F = 66422 = x1.0135.
	wire [17:0] g_vol_raw = (R39_FITTED ? 18'd65536 : 18'd0)
	                      + (vol[0] ? 18'd539   : 18'd0)
	                      + (vol[1] ? 18'd1013  : 18'd0)
	                      + (vol[2] ? 18'd2089  : 18'd0)
	                      + (vol[3] ? 18'd4076  : 18'd0)
	                      + (vol[4] ? 18'd8570  : 18'd0)
	                      + (vol[5] ? 18'd16712 : 18'd0)
	                      + (vol[6] ? 18'd33423 : 18'd0);
	// VOL_HEADROOM is 65536 in the shipped core, i.e. the identity.
	wire signed [35:0] g_vol_m = $signed({1'b0, g_vol_raw}) * $signed(18'(VOL_HEADROOM));
	wire        [17:0] g_vol   = 18'(g_vol_m >>> 16);

	wire signed [37:0] out_m = mix_r * $signed({1'b0, g_vol});
	logic signed [21:0] out_r;
	always_ff @(posedge clk) begin
		if (reset) out_r <= '0;
		else       out_r <= 22'(out_m >>> 16);
	end

	function automatic logic signed [15:0] sat16(input logic signed [21:0] v);
		if      (v >  22'sd32767) sat16 = 16'sd32767;
		else if (v < -22'sd32768) sat16 = 16'sh8000;
		else                      sat16 = v[15:0];
	endfunction

	wire sat_now = (out_r > 22'sd32767) || (out_r < -22'sd32768);

	logic clip_sticky;
	always_ff @(posedge clk) begin
		if (reset)                         clip_sticky <= 1'b0;
		else if (ce && sat_now && !bypass) clip_sticky <= 1'b1;
	end
	assign clipped = clip_sticky;

	// bypass: no filters or level laws, the raw sum, for comparison with MAME.
	// The core ties it to 0.
	wire signed [21:0] raw = {{5{ym_sum[16]}}, ym_sum} + {{6{oki_in[15]}}, oki_in};
	assign out = bypass ? sat16(raw) : sat16(out_r);

	// ---- taps ---------------------------------------------------------------
	function automatic logic signed [15:0] sat18(input logic signed [17:0] v);
		if      (v >  18'sd32767) sat18 = 16'sd32767;
		else if (v < -18'sd32768) sat18 = 16'sh8000;
		else                      sat18 = v[15:0];
	endfunction

	assign dbg_ym_lad  = sat18(ym_lad_r);
	assign dbg_ym      = sat18(ym_path);
	assign dbg_oki_s2  = sat18(oki_s2);
	assign dbg_oki_s3  = sat18(oki_s3);
	assign dbg_oki     = sat18(oki_path);
	assign dbg_premix  = sat16({{2{mix_r[19]}}, mix_r});

endmodule
