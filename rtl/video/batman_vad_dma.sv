`timescale 1ns/1ps
//============================================================================
//  Batman VAD DMA channel: the end-of-frame (EOF) register reload, the
//  linescroll fetch and the playfield attribute autostore.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  The manual lacks the VAD sheets; this follows MAME's atarivad plus what the
//  game program does.  All three jobs share one enable, `dma_enable` = reg 00
//  bit 15 & !bit 14.  The game sets bit 14 around every edit of these tables;
//  MAME ignores reg 00, but those critical sections only make sense if bit 14
//  suspends the DMA.
//
//  1. EOF reload: the 64 words just below the SLIP table are read back into
//     the register file once a frame.  batman_vad_regs sequences it; this
//     module generates the addresses.  It runs during vertical blanking, the
//     only time the video RAM has DMA slots (MAME does it at line 0).
//  2. Linescroll: with OLS_EN (reg 0A bit 13) the VAD reads two words per line
//     from alpha columns 48 + 2 * (line mod 8) and +1 of character row
//     line / 8.  Batman never sets OLS_EN, so the game never uses this path.
//  3. Attribute autostore: with OAS_EN (reg 0A bit 7, which the game does
//     set) a CPU write to PF1's or PF2's code RAM also writes the attribute
//     RAM at the same tile index: the high byte from reg 1C for PF1, the low
//     byte from reg 1D for PF2.  batman_vram issues it as a second posted write.
//  The SLIP head-link read belongs to batman_mob, and the scanline interrupt
//  to batman_vad_sync.
//============================================================================

module batman_vad_dma #(
	// 1 = take the autostore byte when the write reaches the RAM; 0 = at the
	// CPU write, as MAME does.  Batman's game cannot tell them apart.
	parameter bit AS_LATCH_DMA = 1'b1
)(
	input  logic        clk,
	input  logic        reset,

	// ---- raster ------------------------------------------------------------
	input  logic        line_start,    // one clk_sys pulse, already on ce_14m
	input  logic  [8:0] vpos,
	input  logic        vblank,

	// ---- enables -----------------------------------------------------------
	input  logic        dma_enable,   // reg 00 bit 15 & !bit 14
	input  logic        ols_en,       // reg 0A bit 13
	input  logic        oas_en,       // reg 0A bit 7

	// ---- bases, as word indices inside video RAM ---------------------------
	input  logic [14:0] base_pf1,
	input  logic [14:0] base_pf2,
	input  logic [14:0] base_attr,
	input  logic [14:0] base_alpha,
	input  logic [14:0] base_slip,

	// ---- the EOF sequencer in batman_vad_regs ------------------------------
	input  logic        eof_req,
	input  logic  [5:0] eof_idx,
	output logic [15:0] eof_data,
	output logic        eof_ack,

	// ---- the linescroll feed into the parameter-word decoder ---------------
	output logic        ls_wr,
	output logic [15:0] ls_d,

	// ---- the attribute latches (regs 1C / 1D) ------------------------------
	input  logic  [7:0] pf1_attr_latch,
	input  logic  [7:0] pf2_attr_latch,

	// ---- the CPU's video-RAM write, watched for the autostore --------------
	input  logic        cpu_wr_stb,   // one pulse per accepted CPU write
	input  logic [14:0] cpu_wr_a,

	// ---- the autostore write, handed to batman_vram's second posted slot ---
	output logic        as_req,
	output logic [14:0] as_a,
	output logic [15:0] as_d,
	output logic  [1:0] as_ds,

	// ---- the scheduled video-RAM DMA port ----------------------------------
	output logic        dma_rq,
	output logic        dma_we,
	output logic [14:0] dma_a,
	output logic [15:0] dma_d,
	input  logic        dma_ack,
	input  logic [15:0] dma_q,

	// ---- status -------------------------------------------------------------
	output logic [10:0] eof_words,    // EOF words fetched this frame
	output logic        eof_late      // the reload did not finish inside VBLANK
);

	// =====================================================================
	//  1. The EOF list address
	// =====================================================================
	// The 64 EOF words sit just below the SLIP list; `base_slip` is already an
	// absolute word index.
	wire [14:0] eof_base = base_slip - 15'd64;

	// =====================================================================
	//  2. The linescroll fetch
	// =====================================================================
	// columns 48 + 2*(line mod 8) and +1, inside character row line / 8.
	wire [14:0] ls_cell = base_alpha
	                    + {4'b0000, vpos[7:3], 6'd48}
	                    + {12'd0, vpos[2:0]} + {12'd0, vpos[2:0]};

	logic ls_pend;      // a line has started and the two words are owed
	logic ls_second;    // the second of the pair

	// =====================================================================
	//  The channel's sequencer
	// =====================================================================
	typedef enum logic [1:0] { D_IDLE, D_EOF, D_LS } dstate_t;
	dstate_t dst;

	wire eof_go = eof_req & dma_enable & vblank;
	wire ls_go  = ls_pend & dma_enable & ols_en;

	always_comb begin
		dma_rq = 1'b0;
		dma_we = 1'b0;
		dma_a  = 15'd0;
		dma_d  = 16'd0;
		case (dst)
			D_EOF: begin dma_rq = 1'b1; dma_a = eof_base + {9'd0, eof_idx}; end
			D_LS:  begin dma_rq = 1'b1; dma_a = ls_cell + {14'd0, ls_second}; end
			default: ;
		endcase
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			dst       <= D_IDLE;
			eof_ack   <= 1'b0;
			eof_data  <= 16'h0000;
			ls_wr     <= 1'b0;
			ls_d      <= 16'h0000;
			ls_pend   <= 1'b0;
			ls_second <= 1'b0;
			eof_words <= 11'd0;
			eof_late  <= 1'b0;
		end else begin
			eof_ack <= 1'b0;
			ls_wr   <= 1'b0;

			if (line_start) begin
				ls_pend   <= ols_en & ~vblank;
				ls_second <= 1'b0;
			end

			// The EOF reload must finish inside vertical blanking.
			if (line_start && vpos == 9'd0) eof_words <= 11'd0;
			if (eof_req && !vblank && dma_enable)     eof_late  <= 1'b1;

			case (dst)
				D_IDLE: begin
					if      (eof_go) dst <= D_EOF;
					else if (ls_go)  dst <= D_LS;
				end
				D_EOF: if (dma_ack) begin
					eof_data  <= dma_q;
					eof_ack   <= 1'b1;
					eof_words <= eof_words + 11'd1;
					dst       <= D_IDLE;
				end
				D_LS: if (dma_ack) begin
					ls_d  <= dma_q;
					ls_wr <= 1'b1;
					if (ls_second) begin
						ls_pend   <= 1'b0;
						ls_second <= 1'b0;
					end else begin
						ls_second <= 1'b1;
					end
					dst <= D_IDLE;
				end
				default: dst <= D_IDLE;
			endcase
		end
	end

	// =====================================================================
	//  3. The attribute autostore
	// =====================================================================
	// Compare the CPU write address against the two code pages (0x1000 words
	// each, so only the top three bits) and write the attribute at the same
	// tile index, in that layer's byte lane.
	wire in_pf1 = (cpu_wr_a[14:12] == base_pf1[14:12]);
	wire in_pf2 = (cpu_wr_a[14:12] == base_pf2[14:12]);
	wire [11:0] tile_idx = cpu_wr_a[11:0];

	logic [7:0] as_byte_lat;
	logic       as_hi_lat;

	always_ff @(posedge clk) begin
		if (reset) begin
			as_req      <= 1'b0;
			as_a        <= 15'd0;
			as_ds       <= 2'b00;
			as_byte_lat <= 8'h00;
			as_hi_lat   <= 1'b0;
		end else begin
			if (cpu_wr_stb && oas_en && dma_enable && (in_pf1 || in_pf2)) begin
				as_req      <= 1'b1;
				as_a        <= base_attr + {3'b000, tile_idx};
				as_hi_lat   <= in_pf1;
				as_byte_lat <= in_pf1 ? pf1_attr_latch : pf2_attr_latch;
				as_ds       <= in_pf1 ? 2'b10 : 2'b01;
			end else begin
				as_req <= 1'b0;
			end
		end
	end

	// The two AS_LATCH_DMA choices differ only if reg 1C / 1D change between
	// the CPU write and the attribute write, which Batman never does.
	wire [7:0] as_byte = AS_LATCH_DMA ? (as_hi_lat ? pf1_attr_latch : pf2_attr_latch)
	                                  : as_byte_lat;
	assign as_d = {as_byte, as_byte};

	/* verilator lint_off UNUSEDSIGNAL */
	// Only the page bits of the two code bases are compared; the low twelve
	// bits are the tile index.
	wire _unused_dma = &{1'b0, ls_cell[14], base_pf1[11:0], base_pf2[11:0], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
