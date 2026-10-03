`timescale 1ns/1ps
//============================================================================
//  Batman VAD 137656-002 at 6F: the raster counters, sync, blanking and the
//  scanline interrupt, all generated from the register file (no timing
//  constants in the data path).
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//  Structure follows skullxbo_sos2_sync.sv of the Skull & Crossbones MiSTer
//  core (GPL-3.0); see NOTICE.md.
//
//  Register fields (register layout as in MAME; the VAD sheet is not in the
//  manual) and Batman's values:
//      reg 01  V_SY_S [11:3]  V_SY_E [2:0]                     0795
//      reg 02  VLAST [15:9]   V_BL_S [8:0]                     0AEF
//      reg 03  scanline interrupt line [8:0]                   00EF
//      reg 04  H_SY_E/2 [15:10]  H_SY_S [9:0]                  5EEF
//      reg 05  LB_CLR [15:12]  H_BL_E /16 [11], /1 [10]  H_BL_S [9:0]  BEB1
//  The end fields are low-bit terminators: an event ends at the next count
//  whose low bits match.  With Batman's values: VBLANK from the end of line
//  239, VSYNC lines 242-244, 262 lines (VLAST applies only past line 255),
//  HSYNC counts 751-813.  H counts at 14.318181 MHz (912 per line, two per
//  pixel), giving 59.92 Hz.
//
//  HBLANK does not decode cleanly from reg 05 for a 336-pixel picture, so the
//  default (HB_MODE = 0) makes a 672-count active window starting HB_PHASE
//  counts into the line; HB_MODE = 1 is the literal register reading.
//
//  The counters free-run from power-up whatever reg 00 says: the main board's
//  LS197 at 12N/P holds the 68000 in reset until it has counted eight /VBLANK
//  edges, so the raster must run before the CPU can program the VAD.  Reg 00
//  bit 15 gates only the scanline interrupt (and the DMA elsewhere).
//============================================================================

module batman_vad_sync #(
	// ---- raster geometry --------------------------------------------------
	parameter int H_TOTAL   = 912,     // counts of 14.318181 MHz per line
	parameter int H_VISIBLE = 336,     // pixels
	// ---- HBLANK placement (see header) -------------------------------------
	parameter int HB_MODE   = 0,       // 0 = fixed-width window, 1 = register literal
	parameter int HB_PHASE  = 0,       // counts from line start to active video
	parameter int HB_ACTIVE = 2 * H_VISIBLE,   // counts of active video
	// ---- scanline interrupt -------------------------------------------------
	// 0 = a comparator on the V counter (fires every frame); 1 = MAME's one-shot
	// timer, re-armed by each reg 03 write.  Both behave the same for Batman,
	// because the EOF reload rewrites reg 03 every frame.
	parameter bit IRQ_ONESHOT = 1'b0
)(
	input  logic        clk,
	input  logic        reset,
	input  logic        ce_14m,

	// ---- the register file ------------------------------------------------
	input  logic        vad_enable,    // reg 00 bit 15, the master enable
	input  logic [15:0] reg_vsy,       // reg 01
	input  logic [15:0] reg_vbl,       // reg 02
	input  logic [15:0] reg_vint,      // reg 03
	input  logic [15:0] reg_hsy,       // reg 04
	input  logic [15:0] reg_hbl,       // reg 05
	input  logic        irq_arm,       // a CPU/EOF write to reg 03
	input  logic        irq_ack,       // a write to reg 1E (data ignored)

	// ---- counters ---------------------------------------------------------
	output logic [9:0]  h,             // 0 .. H_TOTAL-1, the 14M count
	output logic [8:0]  v,             // 0 .. VLAST
	output logic [9:0]  hd,            // display count (h rotated by HB_PHASE)

	// ---- blanking (active high) and sync (active low) ---------------------
	output logic        hsync_n,       // /HSYNC as the VAD pin emits it
	output logic        vsync_n,       // /VSYNC
	output logic        hblank,
	output logic        vblank,
	output logic        hde, vde,      // display enable
	output logic [9:0]  hpos,          // 0 .. H_VISIBLE-1 while hde
	output logic [8:0]  vpos,          // = v
	// The line after `v`, wrapped at VLAST.  The layer prefetch reaches into
	// the next line near the end of each line, and at the frame wrap `v + 1`
	// would be 262 instead of 0.
	output logic [8:0]  v_next,

	// ---- markers, one clk_sys cycle wide ----------------------------------
	output logic        line_start,    // h == 0
	output logic        frame_start,   // h == 0 and v == 0
	output logic        vblank_start,  // the line VBLANK asserts on
	output logic        eof_window,    // VBLANK, when the EOF DMA may run

	// ---- the scanline interrupt -------------------------------------------
	output logic        vint_n         // /VINT to the IPL encoder (level 4)
);

	// =====================================================================
	// The register fields
	// =====================================================================
	wire [8:0] v_sy_s = reg_vsy[11:3];      // 0FF8
	wire [2:0] v_sy_e = reg_vsy[2:0];       // 0007
	wire [6:0] v_last = reg_vbl[15:9];      // FE00
	wire [8:0] v_bl_s = reg_vbl[8:0];       // 01FF
	wire [8:0] v_int  = reg_vint[8:0];      // 01FF
	wire [5:0] h_sy_e2= reg_hsy[15:10];     // FC00, the end / 2
	wire [9:0] h_sy_s = reg_hsy[9:0];       // 03FF
	wire [9:0] h_bl_s = reg_hbl[9:0];       // 03FF
	wire [4:0] h_bl_e = {reg_hbl[11], 3'b000, reg_hbl[10]};  // 0800 = /16, 0400 = /1
	// reg 05 bits 15-12 (F000) are the line-buffer clear field; the line
	// buffers erase behind the read pointer instead (batman_lb), so it is unused.

	// The HSYNC terminator: the low 7 bits of 2 * (H_SY_E/2).
	wire [6:0] hs_e_lo = {h_sy_e2, 1'b0};

	localparam logic [9:0] HTOT = H_TOTAL[9:0];

	// =====================================================================
	// The counters
	// =====================================================================
	wire        last_h  = (h == HTOT - 10'd1);
	// VLAST is a low-bit terminator that only applies past line 255 (v[8]).
	wire        last_v  = v[8] & (v[6:0] == v_last);
	wire [9:0]  h_next  = last_h ? 10'd0 : (h + 10'd1);
	wire [8:0]  v_step  = last_h ? (last_v ? 9'd0 : (v + 9'd1)) : v;

	always_ff @(posedge clk) begin
		if (reset) begin
			h <= 10'd0;
			v <= 9'd0;
		end else if (ce_14m) begin                // free-running (see header)
			h <= h_next;
			v <= v_step;
		end
	end

	// The display count: a second counter that restarts HB_PHASE counts into
	// the line.
	localparam logic [9:0] HPHASE = HB_PHASE[9:0];
	always_ff @(posedge clk) begin
		if (reset)                        hd <= 10'd0;
		else if (ce_14m)                  hd <= (h_next == HPHASE) ? 10'd0
		                                        : ((hd == HTOT - 10'd1) ? 10'd0 : hd + 10'd1);
	end

	// =====================================================================
	// Sync: set on the start comparator, cleared on the low-bit terminator
	// =====================================================================
	logic hs, vs;
	always_ff @(posedge clk) begin
		if (reset) begin
			hs <= 1'b0;
			vs <= 1'b0;
		end else if (ce_14m) begin
			if      (h_next == h_sy_s)                 hs <= 1'b1;
			else if (hs && (h_next[6:0] == hs_e_lo))   hs <= 1'b0;

			if (last_h) begin
				if      (v_step == v_sy_s)                 vs <= 1'b1;
				else if (vs && (v_step[2:0] == v_sy_e))    vs <= 1'b0;
			end
		end
	end
	assign hsync_n = ~hs;
	assign vsync_n = ~vs;

	// =====================================================================
	// Blanking
	// =====================================================================
	// VBLANK asserts at the end of line V_BL_S and clears at the frame wrap.
	logic vb;
	always_ff @(posedge clk) begin
		if (reset)                                vb <= 1'b1;
		else if (ce_14m && last_h) begin
			if      (last_v)          vb <= 1'b0;      // entering line 0
			else if (v == v_bl_s)     vb <= 1'b1;      // entering V_BL_S + 1
		end
	end
	assign vblank = vb;

	// HBLANK, both readings (see header)
	localparam logic [9:0] HBACT = HB_ACTIVE[9:0];
	logic hb_lit;                                  // HB_MODE = 1's latch
	always_ff @(posedge clk) begin
		if (reset)                        hb_lit <= 1'b1;
		else if (ce_14m) begin
			if      (h_next == h_bl_s)                            hb_lit <= 1'b1;
			else if (hb_lit && ((h_next[4:0] & h_bl_e) == h_bl_e)
			         && (h_bl_e != 5'd0))                         hb_lit <= 1'b0;
		end
	end
	assign hblank = (HB_MODE == 0) ? (hd >= HBACT) : hb_lit;

	assign hde  = ~hblank;
	assign vde  = ~vblank;
	assign hpos = {1'b0, hd[9:1]};                          // two counts per pixel
	assign vpos = v;
	assign v_next = last_v ? 9'd0 : (v + 9'd1);

	// =====================================================================
	// Markers
	// =====================================================================
	assign line_start   = ce_14m & (h == 10'd0);
	assign frame_start  = line_start & (v == 9'd0);
	assign vblank_start = ce_14m & last_h & (v == v_bl_s);
	assign eof_window   = vb;

	// =====================================================================
	// The scanline interrupt
	// =====================================================================
	logic irq, armed;
	wire  hit = ce_14m & vad_enable & last_h & (v_step == v_int);

	always_ff @(posedge clk) begin
		if (reset) begin
			irq   <= 1'b0;
			armed <= 1'b0;
		end else begin
			if (irq_arm) armed <= 1'b1;
			if (irq_ack) irq   <= 1'b0;
			else if (hit && (armed | ~IRQ_ONESHOT)) begin
				irq <= 1'b1;
				if (IRQ_ONESHOT) armed <= 1'b0;
			end
		end
	end
	assign vint_n = ~irq;

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, reg_vsy[15:12], reg_vint[15:9], reg_hbl[15:12], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
