`timescale 1ns/1ps
//============================================================================
//  Batman clock-enable tree.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.  The enable-tree idiom
//  follows the Skull & Crossbones MiSTer core (GPL-3.0); see NOTICE.md.
//
//  One clock domain: clk_sys = 57.272727 MHz = 4 x the 14.318181 MHz crystal.
//  Every enable is an integer divide of clk_sys:
//     ce_14m  /4   14.318181 MHz  VAD 14M; also the 68000 clock in this core
//     ce_7m   /8    7.159091 MHz  pixel clock (456 x 262 raster)
//     ce_3m58 /16   3.579545 MHz  YM2151 (JSA III crystal)
//     ce_1m79 /32   1.789772 MHz  6502 phi0
//     ce_1m19 /48   1.193182 MHz  MSM6295 (3.579545 / 3)
//  The first four decode one counter, so each slower enable is a strict subset
//  of every faster one.  The cycle in which an enable is high is the last
//  clk_sys cycle of its period.  The raster itself comes from the VAD
//  (batman_vad_sync).
//============================================================================

module batman_clocks (
	input  logic        clk_sys,        // 57.272727 MHz

	output logic        ce_14m,
	output logic        ce_7m,
	output logic        ce_3m58,
	output logic        ce_1m79,
	output logic        ce_1m19
);

	// =====================================================================
	//  clock enables
	// =====================================================================
	// Free-running /32 counter; every enable decodes it.  No reset and no
	// initialiser: it powers up at 0, which fixes the enable phase.
	logic [4:0] ce_cnt;
	always_ff @(posedge clk_sys) ce_cnt <= ce_cnt + 5'd1;

	assign ce_14m  = (ce_cnt[1:0] == 2'd0);   // 14.318181 MHz
	assign ce_7m   = (ce_cnt[2:0] == 3'd0);   //  7.159091 MHz  PIXEL
	assign ce_3m58 = (ce_cnt[3:0] == 4'd0);   //  3.579545 MHz  YM2151
	assign ce_1m79 = (ce_cnt      == 5'd0);   //  1.789772 MHz  6502

	// The MSM6295's 1.193182 MHz = clk_sys / 48, from its own counter.
	logic [5:0] oki_cnt;
	always_ff @(posedge clk_sys) oki_cnt <= (oki_cnt == 6'd47) ? 6'd0 : oki_cnt + 6'd1;
	assign ce_1m19 = (oki_cnt == 6'd0);

endmodule
