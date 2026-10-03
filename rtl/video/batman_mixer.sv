`timescale 1ns/1ps
//============================================================================
//  Batman colour-RAM address generator: GALs 136085-1006 (9D), 1004 (9B),
//  1003 (9C) and 1005 (11D) wired together, plus the stain run latch.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//  Structure follows skullxbo_prio.sv of the Skull & Crossbones MiSTer core
//  (GPL-3.0); see NOTICE.md.
//
//  9D computes PF/M; 9B turns it and the alpha pixel into CS1/CS0 and CRA4:1;
//  9C gives CRA10:5; 11D decodes the stain markers.  CRA1..CRA10 are one
//  pixel-clock register deep (registered outputs of 9B/9C); CS0/CS1 are
//  combinational on 9B.  The MO pen `mo_pen_n` is active low, as the inverted
//  stamp ROM delivers it; the MO colour `mo_col` and `pfx` are active high.
//
//  Stain (MAME's name for it): a motion object with priority bit MPR2 set is
//  not drawn.  Its pixels mark where a horizontal run starts and ends, and
//  every pixel inside the run is "stained": it reads its colour from the
//  upper half of the colour RAM.
//
//  Colour-RAM index: [10] stain, [9] CS1 (playfield), [8] which playfield or
//  MO, [7:0] colour:pen.  0x000-0x03F alpha, 0x100-0x1FF MOs, 0x200-0x2FF PF1,
//  0x300-0x3FF PF2, 0x400-0x7FF the stained copies of these.
//============================================================================

module batman_mixer #(
	// ---- where the stain latch joins the colour-RAM address (CRA11) ------
	//   0 = not joined, CRA11 low (the module default).
	//   1 = joined after the 9B/9C mux, so alpha pixels are stained too; the
	//       core uses this, and it matched MAME's frames.
	//   2 = only playfield and MO pixels are stained (CS0 | CS1).
	parameter int STAIN_JOIN = 0,
	// ---- what 9D pins 15 and 16 are wired to (the sheet is missing) ------
	//   0 = PFX3 of the selected playfield and PFXS; reproduces MAME.
	//   1 = bit 3 of each playfield's pen.
	parameter int PFM_QUALIFIER = 0
)(
	input  logic        clk,          // clk_sys, 57.272727 MHz
	input  logic        reset,
	input  logic        ce,           // one pulse per pixel (ce_7m)

	// ---- the playfield, after the PF1-vs-PF2 selection -------------------
	input  logic [9:0]  pfx,          // PFX9:8 priority, PFX7:4 colour, PFX3:0 pen
	input  logic        pfxs,         // 0 = PF1 (foreground) won, 1 = PF2
	input  logic [3:0]  pf1_pen,      // only used when PFM_QUALIFIER = 1
	input  logic [3:0]  pf2_pen,      // only used when PFM_QUALIFIER = 1

	// ---- the motion object, with the board's polarities -----------------
	input  logic [3:0]  mo_pen_n,     // /MPX3:0, active low (1111 = pen 0)
	// The same bus before MPR2 objects are hidden.  An MPR2 object draws no
	// visible pixel (as in MAME), but 11D still needs its pen to run the
	// stain.  Tie to `mo_pen_n` where there is no MO path.
	input  logic [3:0]  mo_pen_n_stain,
	input  logic [3:0]  mo_col,       // MPX7:4, active high
	input  logic [2:0]  mpr,          // MPR2:0

	// ---- the alphanumerics -----------------------------------------------
	input  logic [1:0]  apix,         // APIX1:0
	input  logic [3:0]  alc,          // ALC3:0
	input  logic        albg,         // ALBG, the alpha "opaque" flag

	// ---- 11D's other board inputs ------------------------------------------
	input  logic        lb_run_en,    // 11D pin 1
	input  logic        lb_phase,     // 11D pin 7, the A/B bank toggle
	input  logic        lb_wr_en,     // 11D pin 8
	input  logic        lb_o13_en_n,  // 11D pin 9
	input  logic        lb_blank,     // 11D pin 11, the global disable

	// ---- outputs ----------------------------------------------------------
	output logic [10:0] cram_index,   // {CRA11, CRA10..CRA1}, one pixel late
	output logic        cs0,          // 9B pin 20, combinatorial
	output logic        cs1,          // 9B pin 21, combinatorial
	output logic        pfm,          // 9D pin 17, combinatorial
	output logic        mo1_n,        // 9D pin 19, "MO byte == 1"
	output logic        stain,        // the CRA11 source before the join
	output logic        lb_strobe_n,  // 11D pin 13
	output logic        lb_phase_cmp  // 11D pin 12
);

	// =====================================================================
	// 9D (136085-1006): PF/M
	// =====================================================================
	// The upper-pen qualifier pair; PFM_QUALIFIER changes only these wires.
	wire q15 = (PFM_QUALIFIER == 0) ? pfx[3]   : pf1_pen[3];
	wire q16 = (PFM_QUALIFIER == 0) ? pfxs     : pf2_pen[3];

	// 9D pins 12 and 18 have no known consumer; they end on unused wires.
	logic p12_9d, pfm_n;

	batman_gal_9d u_9d (
		.p1 (mo_pen_n[0]), .p2 (mo_pen_n[1]), .p3 (mo_pen_n[2]), .p4 (mo_pen_n[3]),
		.p5 (mo_col[0]),   .p6 (mo_col[1]),   .p7 (mo_col[2]),   .p8 (mo_col[3]),
		.p9 (mpr[0]),
		.p11(mpr[1]),
		.p13(pfx[9]),      // PFX9, selected playfield priority bit 1
		.p14(pfx[8]),      // PFX8, selected playfield priority bit 0
		.p15(q15),
		.p16(q16),
		.p12(p12_9d),      // unused OLMC
		.p17(pfm),
		.p18(pfm_n),       // /PF/M, destination unknown
		.p19(mo1_n)        // unconnected: unlike ThunderJaws, Batman does not
		                   // OR this into PF/M
	);

	// =====================================================================
	// 9B (136085-1004): CS0, CS1 and CRA4:1
	// =====================================================================
	logic [3:0] cra_4_1;

	batman_gal_9b u_9b (
		.clk(clk), .ce(ce),
		.p2 (mo_pen_n[0]), .p3 (mo_pen_n[1]), .p4 (mo_pen_n[2]), .p5 (mo_pen_n[3]),
		.p6 (pfx[0]),      .p7 (pfx[1]),      .p8 (pfx[2]),      .p9 (pfx[3]),
		.p10(apix[0]),     .p11(apix[1]),
		.p13_oe_n(1'b0),   // the board ties /OE low
		.p14(alc[1]),      .p15(alc[0]),
		.p22(albg),
		.p23(pfm),         // from 9D pin 17
		.p16(cra_4_1[0]), .p17(cra_4_1[1]), .p18(cra_4_1[2]), .p19(cra_4_1[3]),
		.p20(cs0), .p21(cs1)
	);

	// =====================================================================
	// 9C (136085-1003): CRA10:5
	// =====================================================================
	logic [5:0] cra_10_5;

	batman_gal_9c u_9c (
		.clk(clk), .ce(ce),
		.p2 (mo_col[0]), .p3 (mo_col[1]), .p4 (mo_col[2]), .p5 (mo_col[3]),
		.p6 (pfx[4]),    .p7 (pfx[5]),    .p8 (pfx[6]),    .p9 (pfx[7]),
		.p10(1'b0),      // wired on the board, used by no product term
		.p11(alc[2]),
		.p13_oe_n(1'b0),
		.p14(alc[3]),
		.p15(cs0),       // from 9B pin 20
		.p22(cs1),       // from 9B pin 21
		.p23(pfxs),      // PFXS
		.p16(cra_10_5[0]), .p17(cra_10_5[1]), .p18(cra_10_5[2]),
		.p19(cra_10_5[3]), .p20(cra_10_5[4]), .p21(cra_10_5[5])
	);

	// =====================================================================
	// 11D (136085-1005): line-buffer phase and the stain markers
	// =====================================================================
	logic p14_n, p15_n, p16_n, p17_n, stain_set_n, stain_clr_n;

	batman_gal_11d u_11d (
		.clk(clk), .reset(reset),
		.p1 (lb_run_en),
		.p2 (mo_pen_n_stain[0]), .p3 (mo_pen_n_stain[1]),
		.p4 (mo_pen_n_stain[2]), .p5 (mo_pen_n_stain[3]),
		.p6 (mpr[2]),      // MPR2, the "special" bit
		.p7 (lb_phase),
		.p8 (lb_wr_en),
		.p9 (lb_o13_en_n),
		.p11(lb_blank),
		.p12(lb_phase_cmp),
		.p13(lb_strobe_n),
		.p14(p14_n), .p15(p15_n), .p16(p16_n), .p17(p17_n),
		.p18(stain_set_n), .p19(stain_clr_n)
	);

	// =====================================================================
	// The stain run: a flip-flop pair beside 11D, set and cleared by its pins
	// 18 (start marker) and 19 (end marker)
	// =====================================================================
	// 11D's own latches cannot hold a run (i7 always forces one pair), so the
	// run lives here.  Behaviour follows MAME's atarimo apply_stain:
	//   * a start pixel stains itself and opens the run;
	//   * every pixel inside the run is stained;
	//   * an end pixel arms `offnext`, and the run closes after the next pixel
	//     unless that pixel is itself a start (so that pixel is still stained).
	// `lb_blank` closes the run, so it cannot cross a line.  MAME runs it to
	// the bitmap edge instead; that makes no visible difference.
	wire stain_set = ~stain_set_n;     // this pixel is a START marker
	wire stain_end = ~stain_clr_n;     // this pixel is an END marker

	logic run_q, offnext_q;
	wire  stain_now = run_q | stain_set;

	always_ff @(posedge clk) begin
		if (reset) begin
			run_q     <= 1'b0;
			offnext_q <= 1'b0;
		end else if (ce) begin
			if (lb_blank) begin
				run_q     <= 1'b0;
				offnext_q <= 1'b0;
			end else begin
				if (stain_set)                 run_q <= 1'b1;
				else if (run_q && offnext_q)   run_q <= 1'b0;
				offnext_q <= stain_now ? stain_end : offnext_q;
			end
		end
	end

	assign stain = stain_now;

	// =====================================================================
	// The colour-RAM index: one pixel deep, like the CRA registers
	// =====================================================================
	logic cra11;

	always_ff @(posedge clk) begin
		if (reset)   cra11 <= 1'b0;
		else if (ce) begin
			case (STAIN_JOIN)
				1:       cra11 <= stain;                 // alpha IS stained
				2:       cra11 <= stain & (cs0 | cs1);   // alpha is NOT stained
				default: cra11 <= 1'b0;                  // not joined
			endcase
		end
	end

	assign cram_index = {cra11, cra_10_5[5], cra_10_5[4], cra_10_5[3],
	                     cra_10_5[2], cra_10_5[1], cra_10_5[0],
	                     cra_4_1[3], cra_4_1[2], cra_4_1[1], cra_4_1[0]};

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, p14_n, p15_n, p16_n, p17_n,
	                 p12_9d, pfm_n, pf1_pen[2:0], pf2_pen[2:0], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
