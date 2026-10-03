// Adapted for Batman from the Skull & Crossbones core's rtl/sound/skullxbo_snd_iir1.sv (GPL-3.0); see NOTICE.md
`timescale 1ns/1ps
//============================================================================
//  batman_snd_iir1 - one first-order RC section as a leaky integrator, used by
//  batman_snd_mix for every single-pole stage of the JSA III analogue chain.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  The leaky-integrator form and the pipelined multiply come from the Bad Lands
//  core's badlands_snd_filter.sv (GPL-3.0).
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.  See LICENSE, NOTICE.md.
//
//      st += k * (x - st)          k = 1 - exp(-2*pi*fc/fs), Q20
//      y   = st                    low-pass  (HIGHPASS = 0)
//      y   = x - st                high-pass (HIGHPASS = 1, a DC blocker)
//
//  k is an input because some poles move at run time when the board's 4066
//  analogue switches change the network (OKI filter, YM volume ladder).
//  fs = ce_1m79 = 1.789773 MHz, so every corner is at fc/fs <= 0.005.  st is
//  Q20 with 18 integer bits (2 bits of headroom over a 16-bit sample).  The
//  multiply is registered on the clk_sys cycle before ce (there are 32 clocks
//  between ce pulses); chaining it into the ce cycle missed timing at 57 MHz.
//============================================================================

module batman_snd_iir1 #(
	parameter bit HIGHPASS = 1'b0        // 0 = low-pass, 1 = DC-blocking high-pass
) (
	input  logic        clk,
	input  logic        ce,              // ce_1m79
	input  logic        reset,
	input  logic [19:0] k,               // Q20 of 1 - exp(-2*pi*fc/fs)
	input  logic signed [17:0] x,
	output logic signed [17:0] y
);

	localparam int HW = 38;              // 18 integer + 20 fraction

	logic signed [HW-1:0] st;
	wire  signed [HW-1:0] x_q20 = {x, 20'd0};
	wire  signed [HW-1:0] err   = x_q20 - st;
	wire  signed [HW+20:0] k_err = err * $signed({1'b0, k});

	logic signed [HW-1:0] k_err_r;

	always_ff @(posedge clk) begin
		if (reset) k_err_r <= '0;
		else       k_err_r <= HW'(k_err >>> 20);
	end

	always_ff @(posedge clk) begin
		if (reset)   st <= '0;
		else if (ce) st <= st + k_err_r;
	end

	// A part-select is unsigned; land it on a signed wire of the same width so
	// the bit pattern survives and the subtraction below is two's complement.
	wire signed [17:0] st_int = st[HW-1:20];

	assign y = HIGHPASS ? (x - st_int) : st_int;

endmodule
