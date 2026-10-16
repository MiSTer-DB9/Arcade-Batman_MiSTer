// Batman analog-output alignment stage: the OSD decode, the read-rate
// generator and the blanking glue around rmonic79's `crt_adjust`
// (rtl/video/crt_adjust.sv, vendored from MiSTer-CRT-Adjust).  Written from
// that project's examples/core_side_snippet.v (GPL-3.0, Umberto Parisi) by way
// of the Blasteroids MiSTer core, re-derived for an 8-clock pixel and for
// feeding arcade_video rather than the VGA_* pins directly.
//
// Copyright (C) 2026 the Batman MiSTer core authors.
// GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
// Sits between batman_core and arcade_video, so the scandoubler, gamma and
// video_freak all see the adjusted raster and pixel enable.  It never touches
// the core's own timing, so the game cannot observe it.
//
// The OSD carries an On/Off and three amounts: CRT H-Size, CRT H-Position and
// CRT V-Shift, all plain two's complement.  H-Position can be built two ways
// inside `crt_adjust`, picked at compile time by `HPOS_MODE`:
//
//   HPOS_CONTENTSHIFT (1)  shifts the CONTENT in the line buffer, HSync native
//   HPOS_SYNCSHIFT    (0)  shifts the HSYNC, content native
//
// The whole engine restarts on one line reference, `hs_ref_out`.  The read-rate
// accumulator below must be reset on that edge rather than on the raw HSync,
// or the picture trembles.
//
// ---------------- HPOS_MODE for Batman: CONTENTSHIFT ------------------------
// Batman's raster, in pixels (one pixel = two counts of the VAD's 14M clock):
//
//     line total        456 px
//     active            px 0 .. 335          (336 px)
//     HSync high        px 375 .. 406
//
// The line buffer's write pointer resets on the HSync rise, so in BUFFER
// coordinates the active region is 81 .. 416: an 81-pixel lead-in and a
// 39-pixel run-out.  The short margin is the RIGHT one.  So:
//
//   * At H-Size 0, H-Position is lossless from -64 up to +39; beyond +39 the
//     right edge of the picture runs off the end of the line.
//   * Enlarging (H-Size > 0) slows the read, so fewer read ticks fit in a line:
//     at H-Position 0 the whole picture still fits up to H-Size +5.  Past that,
//     a NEGATIVE H-Position pulls the content earlier and buys the room back.
//
// These are the same limits the older H-Size stage had.  CONTENTSHIFT is
// upstream's default and the only mode that can trade lead-in for room on the
// right.  If a real CRT ever shows a black block at the right edge, set
// HPOS_MODE to 0 here and nothing else changes.
//
// ---------------- the read rate, and why 64/CLK_PER_PIX ---------------------
// Upstream steps the read period in quarter clocks because its reference
// core's pixel is 16 clk_sys cycles: 64 quarters = one pixel, so one H-Size
// click is 1/64 = 1.56%.  Batman's pixel is 8 (ce_7m = clk_sys/8).  The
// accumulator below counts 1/CLK_PER_PIX-th of a clock instead, which keeps
// the 1.56% step at any pixel period:
//
//     period = 64 + hsize      units, where 64 units == CLK_PER_PIX clocks
//     acc   += 64/CLK_PER_PIX  per clock
//
// so hsize spans 48..79 units = 6.00..9.875 clocks per pixel at CLK_PER_PIX = 8.
// ACC_STEP must stay an exact integer (CLK_PER_PIX a power of two) or the OSD
// step drifts away from the menu text.

module batman_analog_adjust #(
	parameter int H_TOTAL     = 456,   // ce_pix ticks per line
	parameter int V_TOTAL     = 262,   // lines per frame
	parameter int CLK_PER_PIX = 8,     // clk_sys cycles per ce_pix (ce_7m = clk_sys/8)
	parameter int HPOS_MODE   = 1,     // 1 = CONTENTSHIFT, 0 = SYNCSHIFT (see above)
	parameter int AW          = 11     // line-buffer address bits, 1024 samples per bank
) (
	input  logic       clk,
	input  logic       ce_pix,

	// OSD
	input  logic       osd_on,         // CRT Adjust Off/On; Off is a bit-exact bypass
	input  logic [4:0] osd_hsize,      // CRT H-Size        +15 / -16   two's complement
	input  logic [6:0] osd_hpos,       // CRT H-Position    +63 / -64   two's complement
	input  logic [5:0] osd_vshift,     // CRT V-Shift       +31 / -32   two's complement

	input  logic [7:0] r_in, g_in, b_in,
	input  logic       hs_in, vs_in, hb_in, vb_in,

	output logic [7:0] r_out, g_out, b_out,
	output logic       hs_out, vs_out, hb_out, vb_out,
	output logic       ce_out
);

	localparam [7:0] ACC_STEP = 8'(64 / CLK_PER_PIX);

	// ---------------- OSD decode ----------------
	// Sampled at ce_pix so a mid-frame menu change lands on a pixel boundary.
	logic              active;
	logic signed [4:0] hsize_s;
	logic signed [8:0] hpos_s;
	logic signed [5:0] vshift_s;

	always_ff @(posedge clk) if (ce_pix) begin
		active   <= osd_on;
		hsize_s  <= $signed(osd_hsize);
		hpos_s   <= 9'($signed(osd_hpos));    // sign-extend 7 -> 9 bits
		vshift_s <= $signed(osd_vshift);
	end

	// ---------------- read-rate generator ----------------
	// Reset on the rise of the module's `hs_ref_out`, never on the raw HSync,
	// so the write side, the module's read counter and this read rate all
	// restart on the same edge.
	wire  hs_ref;
	logic hs_ref_d;
	always_ff @(posedge clk) hs_ref_d <= hs_ref;
	wire  hs_ref_rise = hs_ref & ~hs_ref_d;

	wire  [7:0] rd_period = 8'd64 + {{3{hsize_s[4]}}, hsize_s};   // 48..79
	logic [7:0] rd_acc;
	wire        rd_tick = (rd_acc + ACC_STEP) >= rd_period;

	always_ff @(posedge clk) begin
		if      (hs_ref_rise) rd_acc <= 8'd0;
		else if (rd_tick)     rd_acc <= rd_acc + ACC_STEP - rd_period;
		else                  rd_acc <= rd_acc + ACC_STEP;
	end

	// When On the line buffer is always live, even at H-Size 0, where rd_tick
	// runs at the same rate as ce_pix but re-phased onto hs_ref.
	wire rd_ce = active ? rd_tick : ce_pix;

	// ---------------- the engine ----------------
	wire [7:0] str_r, str_g, str_b;
	wire       str_hs, str_vs, str_hb, str_vb;

	crt_adjust #(
		.VTOTAL    (V_TOTAL),
		.HTOTAL    (H_TOTAL),
		.HPOS_MODE (HPOS_MODE),
		.AW        (AW),
		.VB_LATE   (0)              // HSync follows the active pixels (see crt_adjust.sv)
	) u_crt_adjust (
		.clk        (clk),
		.pxl_cen    (ce_pix),
		.pxl2_cen   (rd_ce),
		.active     (active),
		.hsize      (hsize_s),      // kept for upstream parity; the rate above is H-Size
		.hoffset    (hpos_s),
		.voffset    (vshift_s),
		.r_in       (r_in), .g_in (g_in), .b_in (b_in),
		.hs_in      (hs_in),        // NATIVE sync in; the module derives hs_ref itself
		.vs_in      (vs_in),
		.hb_in      (hb_in | vb_in),
		.vb_in      (vb_in),        // the true vertical blank, not the combined blank
		.r_out      (str_r), .g_out (str_g), .b_out (str_b),
		.hs_out     (str_hs), .vs_out (str_vs),
		.hb_out     (str_hb), .vb_out (str_vb),
		.hs_ref_out (hs_ref)
	);

	// ---------------- the vertical blank handed to arcade_video ------------
	// arcade_video latches VBlank where HBlank falls, so the VBlank it sees must
	// line up with the line the read side is emitting, not with the write side.
	// The bank closed at line L's HSync rise holds line L and is read out during
	// line L+1, so VBlank sampled once per line on that same edge is exactly
	// right.  This is one flop, matching VB_LATE = 0 inside crt_adjust; the two
	// must agree or the bottom line of the picture is lost or a stale one shown.
	// `str_vb` is the native, write-rate blank and is used only while Off.
	logic hs_ref_q;
	always_ff @(posedge clk) if (ce_pix) hs_ref_q <= hs_ref;
	wire  ref_line_tick = ce_pix & hs_ref & ~hs_ref_q;

	logic vb_read;
	always_ff @(posedge clk) if (ref_line_tick) vb_read <= vb_in;

	// ---------------- DE follows the picture ----------------
	// Upstream's core-side snippet also builds a `de_osd` window whose rising
	// edge is pinned to the NATIVE active start, so the MiSTer OSD (which
	// centres itself on the rise of VGA_DE) does not slide with H-Position.
	// It assumes the adjusted picture never starts before the native one, and
	// on this raster a negative H-Position is exactly the direction that buys
	// back room when H-Size enlarges: the content would open before the window
	// and lose its left edge.  So DE here follows the picture, and the OSD
	// moves with H-Position.

	// ---------------- outputs ----------------
	// Off: `crt_adjust` is in its own bypass, so everything here is the native
	// stream delayed by the module's input registers.
	assign r_out  = str_r;
	assign g_out  = str_g;
	assign b_out  = str_b;
	assign hs_out = str_hs;
	assign vs_out = str_vs;
	assign hb_out = str_hb;
	assign vb_out = active ? vb_read : str_vb;
	assign ce_out = rd_ce;

endmodule
