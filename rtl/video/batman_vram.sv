`timescale 1ns/1ps
//============================================================================
//  Batman video RAM (32K x 16 at 0x2F0000, single-ported) and the VAD's
//  access-slot schedule.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//  Structure follows skullxbo_vram.sv of the Skull & Crossbones MiSTer core
//  (GPL-3.0); see NOTICE.md.
//
//  The board has one access per pixel (456 a line), eight per 8-pixel group:
//  five layer fetches (PF1 code/attribute, PF2 code/attribute, alpha), two
//  motion-object words and one CPU slot.  In blanking the layer slots are
//  free, giving MO 4 / CPU 2 / VAD DMA 2.  (The VAD sheet is not in the manual;
//  this schedule is inferred from MAME, the VAD registers and frame matching.)
//  clk_sys gives eight clocks per pixel, so here each pixel is split into
//  eight phases: ph 0-4 the layers, ph 5 MO, ph 6 CPU, ph 7 VAD DMA.  The
//  layers fetch every pixel, which cannot change a pixel since their addresses
//  depend only on the raster; the MO and CPU get exactly the board's share per
//  group (MiSTer-only difference: the layers are oversampled).
//
//  CPU access: reads always wait for a CPU slot.  Writes wait only if OVRDTACK
//  (reg 0A bit 5) is set; Batman leaves it clear, so writes are posted and
//  answered at once.  /VDTACK is held until /VRAM ends (VDTACK_LEVEL = 1),
//  since the main board's GAL samples it combinationally.  OSLORAM would halve
//  the MO slots (MO_SLOTS_*); O_DVDMA and OADROEN have no effect here, and
//  Batman sets none of them.
//
//  The 68000 drives the address bus high during interrupt acknowledge, so the
//  F138 strobes /VRAM then too; by default (IACK_STEALS = 0) that cycle is
//  ignored.
//
//  The RAM is two byte-lane arrays; a single 16-bit array with byte writes is
//  inferred by Quartus 17 as flip-flops.
//============================================================================

module batman_vram #(
	// ---- /VDTACK: level held to the end of the cycle, or a one-clk pulse --
	parameter bit VDTACK_LEVEL   = 1'b1,
	// ---- MO word slots per 8-pixel group (OSLORAM would halve these) ------
	parameter int MO_SLOTS_ACT   = 2,
	parameter int MO_SLOTS_BLANK = 4,
	// ---- the CPU's own share, per 8-pixel group --------------------------
	parameter int CPU_SLOTS_ACT   = 1,
	parameter int CPU_SLOTS_BLANK = 2,
	// ---- 1 = the IACK cycle's /VRAM strobe takes a CPU slot --------------
	parameter bit IACK_STEALS    = 1'b0
)(
	input  logic        clk,
	input  logic        reset,

	// ---- the raster phase -------------------------------------------------
	input  logic        ce_14m,
	input  logic  [9:0] hd,          // display count: hd[0] = pix_half,
	                                 // hd[3:1] = the pixel inside the group
	input  logic        blank,       // HBLANK | VBLANK
	// ---- the five layer fetch ports (address in, held word out) -----------
	input  logic [14:0] pf1_code_a,
	input  logic [14:0] pf1_attr_a,
	input  logic [14:0] pf2_code_a,
	input  logic [14:0] pf2_attr_a,
	input  logic [14:0] al_a,
	output logic [15:0] pf1_code_q,
	output logic [15:0] pf1_attr_q,
	output logic [15:0] pf2_code_q,
	output logic [15:0] pf2_attr_q,
	output logic [15:0] al_q,

	// ---- the motion-object walk (req held, ack is a one-clk pulse) --------
	input  logic        mo_req,
	input  logic [14:0] mo_a,
	output logic        mo_ack,
	output logic [15:0] mo_q,

	// ---- the VAD's DMA channel (EOF reload, linescroll) -------------------
	input  logic        dma_req,
	input  logic        dma_we,
	input  logic [14:0] dma_a,
	input  logic [15:0] dma_d,
	output logic        dma_ack,
	output logic [15:0] dma_q,

	// ---- the 68000 --------------------------------------------------------
	input  logic        cpu_cs,      // decoded video-RAM select, level
	input  logic        cpu_we,
	input  logic  [1:0] cpu_ds,      // {/WU, /WL} as byte enables, active high
	input  logic [14:0] cpu_a,
	input  logic [15:0] cpu_din,
	output logic [15:0] cpu_dout,
	output logic        cpu_grant,   // -> /VDTACK (active high here)
	input  logic        ovrdtack,    // reg 0A bit 5: writes wait for a slot
	input  logic        iack,        // the 68000 is in an IACK cycle
	output logic        cpu_wr_stb,  // one pulse per accepted CPU write
	output logic [14:0] cpu_wr_a,

	// ---- the attribute autostore's second posted write -------------------
	// batman_vad_dma raises this the cycle after `cpu_wr_stb`; the two writes
	// use consecutive CPU slots.
	input  logic        as_req,
	input  logic [14:0] as_a,
	input  logic [15:0] as_d,
	input  logic  [1:0] as_ds,

	// ---- preload port for simulation --------------------------------------
	// Loads a captured frame's video RAM with the CPU parked.  Tied off in the
	// core, so Quartus removes it.
	input  logic        init_wr,
	input  logic [14:0] init_a,
	input  logic [15:0] init_d,

	// ---- usage counters, for debugging ------------------------------------
	output logic [10:0] mo_words_line,   // MO word slots granted this line
	output logic [10:0] cpu_words_line,  // CPU word slots granted this line
	output logic [10:0] dma_words_line,
	output logic [15:0] cpu_wait_worst,  // clk_sys the CPU has ever waited
	output logic        layer_late       // a layer slot was ever stolen
);

	// =====================================================================
	//  The phase inside the pixel
	// =====================================================================
	// `sub` is the clk index since the last ce_14m, so {hd[0], sub} counts
	// 0..7 across one pixel with hd stable from sub == 0 onwards (hd is
	// updated by batman_vad_sync on the ce_14m edge itself).
	logic [1:0] sub;
	always_ff @(posedge clk) begin
		if (reset)       sub <= 2'd0;
		else if (ce_14m) sub <= 2'd0;
		else             sub <= sub + 2'd1;
	end
	wire [2:0] ph = {hd[0], sub};
	wire [2:0] g  = hd[3:1];          // the pixel's index inside the group

	// =====================================================================
	//  The slot table
	// =====================================================================
	// Active video: MO at ph 5 on MO_SLOTS_ACT of the eight pixels, the CPU at
	// ph 6 on CPU_SLOTS_ACT of them, the VAD DMA never.  Blanking: MO / CPU /
	// DMA all get more slots.
	localparam int MOA = (MO_SLOTS_ACT   > 8) ? 8 : MO_SLOTS_ACT;
	localparam int MOB = (MO_SLOTS_BLANK > 8) ? 8 : MO_SLOTS_BLANK;
	localparam int CPA = (CPU_SLOTS_ACT   > 8) ? 8 : CPU_SLOTS_ACT;
	localparam int CPB = (CPU_SLOTS_BLANK > 8) ? 8 : CPU_SLOTS_BLANK;

	// Spread N slots evenly over the 8 pixels: N = 2 gives g = 0, 4;
	// N = 4 gives g = 0, 2, 4, 6.
	function automatic bit spread(input logic [2:0] gg, input int n);
		int a, b;
		begin
			if (n <= 0)      spread = 1'b0;
			else if (n >= 8) spread = 1'b1;
			else begin
				a = (int'(gg)       * n) / 8;
				b = ((int'(gg) + 1) * n) / 8;
				spread = (a != b);
			end
		end
	endfunction

	wire mo_slot  = (ph == 3'd5) && spread(g, blank ? MOB : MOA);
	wire cpu_slot = (ph == 3'd6) && spread(g, blank ? CPB : CPA);
	// The VAD DMA owns phase 7 throughout blanking (plenty for the EOF reload).
	// It must not take the layer phases: the layer prefetch runs through HBLANK
	// to prime the next line, and a lost fetch there corrupts the left edge.
	wire dma_slot = blank && (ph == 3'd7);

	// =====================================================================
	//  The scheduled port
	// =====================================================================
	// One address per clk_sys.  The layer phases are unconditional, so
	// `layer_late` can never be set.
	logic [14:0] sa;
	logic        swe;
	logic  [1:0] sds;
	logic [15:0] sd;

	// Posted-write queue (OVRDTACK clear: writes do not stall).  Two entries,
	// because an autostore write follows its CPU write.
	logic        post_v,  post2_v;
	logic [14:0] post_a,  post2_a;
	logic [15:0] post_d,  post2_d;
	logic  [1:0] post_ds, post2_ds;

	// the CPU's own latched request
	logic        cpu_pend;      // a cycle is waiting for its slot
	logic        cpu_hit;       // this slot is serving the CPU
	logic        cpu_done;      // the grant

	wire cpu_active = cpu_cs & ~(iack & ~IACK_STEALS);
	wire cpu_wr     = cpu_active &  cpu_we;
	wire cpu_rd     = cpu_active & ~cpu_we;
	// A write that need not wait is posted and answered at once.  The queue
	// must have room for a following autostore write; if it is not empty the
	// cycle waits for a slot instead.
	wire post_take  = cpu_wr & ~ovrdtack & ~cpu_done & ~post_v & ~post2_v;

	always_comb begin
		sa  = 15'd0;
		swe = 1'b0;
		sds = 2'b11;
		sd  = 16'd0;
		cpu_hit = 1'b0;
		case (ph)
			3'd0: sa = pf1_code_a;
			3'd1: sa = pf1_attr_a;
			3'd2: sa = pf2_code_a;
			3'd3: sa = pf2_attr_a;
			3'd4: sa = al_a;
			default: ;
		endcase
		// ph 5 / 6 / 7 belong to the MO, the CPU and the DMA; posted writes
		// drain first in a CPU slot, then a waiting CPU cycle is served.
		if (dma_slot && dma_req) begin
			sa  = dma_a;
			swe = dma_we;
			sd  = dma_d;
		end
		if (mo_slot && mo_req) begin
			sa  = mo_a;
			swe = 1'b0;
		end
		if (cpu_slot) begin
			if (post_v) begin
				sa  = post_a;
				swe = 1'b1;
				sds = post_ds;
				sd  = post_d;
			end else if (post2_v) begin
				sa  = post2_a;
				swe = 1'b1;
				sds = post2_ds;
				sd  = post2_d;
			end else if (cpu_pend) begin
				sa      = cpu_a;
				swe     = cpu_we;
				sds     = cpu_ds;
				sd      = cpu_din;
				cpu_hit = 1'b1;
			end
		end
	end

	// =====================================================================
	//  The RAM, one array per byte lane (see the header)
	// =====================================================================
	logic [7:0] vr_hi [0:32767];
	logic [7:0] vr_lo [0:32767];
	logic [15:0] sq;

	wire [14:0] aa  = init_wr ? init_a : sa;
	wire        awh = init_wr | (swe & sds[1]);
	wire        awl = init_wr | (swe & sds[0]);
	wire [15:0] ad  = init_wr ? init_d : sd;

	always_ff @(posedge clk) begin
		if (awh) vr_hi[aa] <= ad[15:8];
		if (awl) vr_lo[aa] <= ad[7:0];
		sq <= {vr_hi[aa], vr_lo[aa]};
	end

`ifndef ALTERA_RESERVED_QIS
	// Simulation only: start zeroed, as the FPGA's block RAM does.
	initial begin
		for (int i = 0; i < 32768; i++) begin
			vr_hi[i] = 8'h00;
			vr_lo[i] = 8'h00;
		end
	end
`endif

	// =====================================================================
	//  Per-client hold registers: the data lands one clk after the slot
	// =====================================================================
	logic [2:0] ph_d;
	logic       mo_slot_d, cpu_hit_d, dma_slot_d, dma_rd_d;
	always_ff @(posedge clk) begin
		ph_d       <= ph;
		mo_slot_d  <= mo_slot & mo_req;
		cpu_hit_d  <= cpu_hit;
		dma_slot_d <= dma_slot & dma_req;
		dma_rd_d   <= dma_slot & dma_req & ~dma_we;
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			pf1_code_q <= 16'h0000;
			pf1_attr_q <= 16'h0000;
			pf2_code_q <= 16'h0000;
			pf2_attr_q <= 16'h0000;
			al_q       <= 16'h0000;
		end else begin
			case (ph_d)
				3'd0: pf1_code_q <= sq;
				3'd1: pf1_attr_q <= sq;
				3'd2: pf2_code_q <= sq;
				3'd3: pf2_attr_q <= sq;
				3'd4: al_q       <= sq;
				default: ;
			endcase
		end
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			mo_ack  <= 1'b0;
			mo_q    <= 16'h0000;
			dma_ack <= 1'b0;
			dma_q   <= 16'h0000;
		end else begin
			mo_ack <= mo_slot_d;
			if (mo_slot_d) mo_q <= sq;
			dma_ack <= dma_slot_d;
			if (dma_rd_d)  dma_q <= sq;
		end
	end

	// =====================================================================
	//  The CPU cycle and /VDTACK
	// =====================================================================
	always_ff @(posedge clk) begin
		cpu_wr_stb <= 1'b0;
		if (reset) begin
			cpu_pend <= 1'b0;
			cpu_done <= 1'b0;
			post_v   <= 1'b0;
			post_a   <= 15'd0;
			post_d   <= 16'd0;
			post_ds  <= 2'b00;
			post2_v  <= 1'b0;
			post2_a  <= 15'd0;
			post2_d  <= 16'd0;
			post2_ds <= 2'b00;
			cpu_wr_a <= 15'd0;
			cpu_dout <= 16'h0000;
		end else begin
			// the autostore entry arrives one clk after `cpu_wr_stb`
			if (as_req) begin
				post2_v  <= 1'b1;
				post2_a  <= as_a;
				post2_d  <= as_d;
				post2_ds <= as_ds;
			end

			if (!cpu_active) begin
				// the cycle has ended: drop the grant and re-arm
				cpu_pend <= 1'b0;
				cpu_done <= 1'b0;
			end else if (!cpu_done) begin
				if (post_take) begin
					// OVRDTACK clear: post the write and answer at once; the
					// RAM takes it in the next CPU slot.
					post_v   <= 1'b1;
					post_a   <= cpu_a;
					post_d   <= cpu_din;
					post_ds  <= cpu_ds;
					cpu_done <= 1'b1;
					cpu_wr_stb <= 1'b1;
					cpu_wr_a   <= cpu_a;
				end else begin
					cpu_pend <= 1'b1;
				end
			end else if (!VDTACK_LEVEL) begin
				// Pulse mode: `cpu_done` lasts one clk and `cpu_pend`
				// staying low marks the cycle as served.
				cpu_done <= 1'b0;
			end

			// the slot itself
			if (cpu_hit) begin
				cpu_pend <= 1'b0;
				cpu_done <= 1'b1;
				if (cpu_we) begin
					cpu_wr_stb <= 1'b1;
					cpu_wr_a   <= cpu_a;
				end
			end
			if (cpu_hit_d) cpu_dout <= sq;

			// the posted writes drain, oldest first, in the slots they are given
			if (cpu_slot) begin
				if      (post_v)  post_v  <= 1'b0;
				else if (post2_v) post2_v <= 1'b0;
			end
		end
	end

	// A read's grant waits one more clk for the RAM data; a write is done as
	// soon as its slot is taken.
	logic cpu_rd_served;
	always_ff @(posedge clk) begin
		if (reset)                 cpu_rd_served <= 1'b0;
		else if (!cpu_active)      cpu_rd_served <= 1'b0;
		else if (cpu_hit_d)        cpu_rd_served <= 1'b1;
	end

	assign cpu_grant = cpu_active & (cpu_we ? cpu_done : cpu_rd_served);

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused_rd = &{1'b0, cpu_rd, 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

	// =====================================================================
	//  Usage counters
	// =====================================================================
	wire line_wrap = ce_14m & (hd == 10'd0);
	logic [15:0] cpu_wait;

	always_ff @(posedge clk) begin
		if (reset) begin
			mo_words_line  <= 11'd0;
			cpu_words_line <= 11'd0;
			dma_words_line <= 11'd0;
			cpu_wait       <= 16'd0;
			cpu_wait_worst <= 16'd0;
			layer_late     <= 1'b0;
		end else begin
			if (line_wrap) begin
				mo_words_line  <= 11'd0;
				cpu_words_line <= 11'd0;
				dma_words_line <= 11'd0;
			end else begin
				if (mo_slot  && mo_req)  mo_words_line  <= mo_words_line  + 11'd1;
				if (cpu_slot && (cpu_pend || post_v || post2_v))
				                         cpu_words_line <= cpu_words_line + 11'd1;
				if (dma_slot && dma_req) dma_words_line <= dma_words_line + 11'd1;
			end

			// how long a CPU cycle has been waiting for its slot
			if (!cpu_active)      cpu_wait <= 16'd0;
			else if (!cpu_grant)  cpu_wait <= cpu_wait + 16'd1;
			if (cpu_active && !cpu_grant && (cpu_wait > cpu_wait_worst))
				cpu_wait_worst <= cpu_wait;

			// Should never fire; it guards against edits to the slot table.
			if ((ph <= 3'd4) && (mo_slot || cpu_slot || dma_slot))
				layer_late <= 1'b1;
		end
	end

endmodule
