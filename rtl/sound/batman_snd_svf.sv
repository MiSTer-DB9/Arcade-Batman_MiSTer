// Adapted for Batman from the Skull & Crossbones core's rtl/sound/skullxbo_snd_svf.sv (GPL-3.0); see NOTICE.md
`timescale 1ns/1ps
//============================================================================
//  batman_snd_svf - one second-order low-pass section as a Chamberlin
//  state-variable filter, used by batman_snd_mix for the YM2151 Sallen-Key
//  filter (corner switched by the LPF bit) and the OKI filter's pole pair.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  Ported from the Vindicators core's vind_jsa_lpf.sv (GPL-3.0), itself from
//  the Toobin' core's toobin_jsa_lpf.sv.  The coefficients are computed in
//  batman_snd_mix from the board's component values.
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.  See LICENSE, NOTICE.md.
//
//      low  = low  + f*band
//      high = in   - low - q*band
//      band = band + f*high
//      y    = low
//  f = 2*sin(pi*f0/fs) and q = 1/Q, both Q16 inputs, because the LPF bit moves
//  the YM filter between 8941 Hz / Q 0.742 and 4312 Hz / Q 0.358 at run time.
//  An SVF is used because f0/fs is only 0.0012-0.005, where a direct-form
//  biquad needs far more coefficient precision.  State is Q16 with 18 integer
//  bits so the small resonant overshoot cannot wrap.  The multiplies are
//  registered between ce pulses, as in batman_snd_iir1.
//============================================================================

module batman_snd_svf
(
	input  logic        clk,
	input  logic        ce,              // ce_1m79
	input  logic        reset,
	input  logic [18:0] f,               // Q16 of 2*sin(pi*f0/fs)
	input  logic [18:0] q,               // Q16 of 1/Q
	input  logic signed [17:0] x,
	output logic signed [17:0] y
);

	localparam int SW = 34;              // 18 integer + 16 fraction

	logic signed [SW-1:0] lp, bp;
	wire  signed [SW-1:0] in_q16 = {x, 16'd0};

	wire signed [19:0] f_c = $signed({1'b0, f});
	wire signed [19:0] q_c = $signed({1'b0, q});

	logic signed [SW-1:0] f_bp_r, q_bp_r, hp_r, f_hp_r;

	wire signed [SW+19:0] f_bp = f_c * bp;
	wire signed [SW+19:0] q_bp = q_c * bp;
	always_ff @(posedge clk) begin
		if (reset) begin
			f_bp_r <= '0; q_bp_r <= '0;
		end else begin
			f_bp_r <= SW'(f_bp >>> 16);
			q_bp_r <= SW'(q_bp >>> 16);
		end
	end

	wire signed [SW-1:0] lp_nxt = lp + f_bp_r;
	wire signed [SW-1:0] hp_sv  = in_q16 - lp_nxt - q_bp_r;
	always_ff @(posedge clk) begin
		if (reset) hp_r <= '0;
		else       hp_r <= hp_sv;
	end

	wire signed [SW+19:0] f_hp = f_c * hp_r;
	always_ff @(posedge clk) begin
		if (reset) f_hp_r <= '0;
		else       f_hp_r <= SW'(f_hp >>> 16);
	end

	wire signed [SW-1:0] bp_nxt = bp + f_hp_r;

	always_ff @(posedge clk) begin
		if (reset) begin
			lp <= '0; bp <= '0;
		end else if (ce) begin
			lp <= lp_nxt;
			bp <= bp_nxt;
		end
	end

	assign y = lp[SW-1:16];

endmodule
