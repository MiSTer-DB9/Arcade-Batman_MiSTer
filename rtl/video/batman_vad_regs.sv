`timescale 1ns/1ps
//============================================================================
//  Batman VAD 137656-002 at 6F: the 32-word register file at 0x2EFFC0, the
//  end-of-frame (EOF) reload and the parameter-word (scroll) decoder.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  The manual lacks the VAD sheet; this follows MAME's atarivad, corrected
//  where the game's own behaviour shows MAME is incomplete:
//  * Reg 00: bit 15 master enable, bit 14 suspends the VAD's DMA channel (the
//    game sets it around every edit of the DMA tables; MAME ignores reg 00).
//  * EOF reload: once a frame, during vertical blanking, words 0x00..EOF_LAST
//    of the EOF table in video RAM are copied into the register file, skipping
//    zero words (reg 0A would otherwise be cleared every frame).  After boot
//    the game writes its scroll registers only through this table, and the
//    reload of reg 03 re-arms the scanline interrupt every frame.
//  * Parameter words carry their destination in bits 3-0 and a 9-bit value in
//    bits 15-7, so any of regs 0x10-0x1B can set any scroll.  One decoder
//    takes CPU writes, EOF words and linescroll words.  Tags: 9 MO X, A PF1 X,
//    B PF2 X, D MO Y, E PF1 Y, F PF2 Y; the rest have no destination.
//  * Regs 0x10-0x12 (MOCON/PCON/GRCON) are passed to the MOB (/MOBWR); their
//    bit meanings are unknown and not modelled.
//  * Reading reg 00 returns the beam: vpos clamped to 255, 0x4000 in VBLANK.
//============================================================================

module batman_vad_regs #(
	parameter int  EOF_LAST       = 'h1B,   // last EOF index replayed (as MAME)
	parameter bit  EOF_SKIP_ZERO  = 1'b1,   // skip zero words (as MAME)
	// Regs 01-1F read back their last value, as in MAME; the game never reads
	// them, so this is unobservable.
	parameter bit  READBACK_SHADOW= 1'b1,
	parameter bit  HONOUR_ENABLE14= 1'b1,   // reg 00 bit 14 suspends the DMA
	// PF2 shares PF1's fine scroll phase (see pf2_xscroll below).  Should stay 1.
	parameter bit  COUPLE_FINE    = 1'b1
)(
	input  logic        clk,
	input  logic        reset,

	// ---- the 68000 port (0x2EFFC0-0x2EFFFF, and the 0x3E alias) ----------
	input  logic        cpu_cs,
	input  logic        cpu_we,
	input  logic  [4:0] cpu_a,          // the register index
	input  logic [15:0] cpu_din,
	output logic [15:0] cpu_dout,

	// ---- the raster, for the reg-00 readback and the DMA trigger ---------
	input  logic  [8:0] vpos,
	input  logic        vblank,
	input  logic        vblank_start,   // one pulse at the VBLANK edge

	// ---- the EOF parameter RAM read port (video RAM 0x2F8F00-0x2F8F7F) ---
	output logic        eof_req,
	output logic  [5:0] eof_idx,
	input  logic [15:0] eof_data,
	input  logic        eof_ack,

	// ---- the linescroll feed into the decoder (batman_vad_dma) ------------
	// Reaches the decoder only, never the register file (it has no index).
	// OLS_EN is 0 on Batman, so it never pulses.
	input  logic        ls_wr,
	input  logic [15:0] ls_d,

	// ---- the register file, fanned out -----------------------------------
	output logic [15:0] reg_enable,     // 00
	output logic [15:0] reg_vsy,        // 01
	output logic [15:0] reg_vbl,        // 02
	output logic [15:0] reg_vint,       // 03
	output logic [15:0] reg_hsy,        // 04
	output logic [15:0] reg_hbl,        // 05
	output logic [15:0] reg_slip,       // 06
	output logic [15:0] reg_apdma,      // 07
	output logic [15:0] reg_pmbase,     // 08
	output logic [15:0] reg_albase,     // 09
	output logic [15:0] reg_opt,        // 0A
	output logic [15:0] reg_mocon,      // 10  -> the MOB
	output logic [15:0] reg_pcon,       // 11  -> the MOB
	output logic [15:0] reg_grcon,      // 12  -> the MOB
	output logic        mob_wr,         // one pulse per 10/11/12 write (/MOBWR)
	output logic  [1:0] mob_sel,        // which of the three

	// ---- the decoded scrolls ---------------------------------------------
	output logic  [8:0] mo_xscroll,     // tag 9
	output logic  [8:0] pf1_xscroll,    // tag A  (MAME m_pf1_xscroll_raw)
	output logic  [8:0] pf2_xscroll,    // tag B  (MAME m_pf0_xscroll_raw),
	                                    //        plus PF1's fine phase
	output logic  [8:0] pf2_xscroll_raw,
	output logic  [8:0] mo_yscroll,     // tag D
	output logic  [8:0] pf1_yscroll,    // tag E
	output logic  [8:0] pf2_yscroll,    // tag F

	// ---- the attribute autostore ------------------------------------------
	output logic  [7:0] pf1_attr_latch, // reg 1C, high byte source
	output logic  [7:0] pf2_attr_latch, // reg 1D, low byte source
	output logic        oas_en,         // reg 0A bit 7, toggled by the game

	// ---- the rest of reg 0A (after the comma: the value Batman uses) -------
	output logic        ols_en,         // bit 13  linescroll, 0
	output logic        oslpink,        // bit 12  split links, 0
	output logic        osloram,        // bit 11  slow MO DMA cycles, 0
	output logic        o_dcdma,        // bit 10  double-time colour-RAM DMA, 1
	output logic        o_dvdma,        // bit  9  double-time video-RAM DMA, 0
	output logic        oadroen,        // bit  8  address bus tri-state, 0
	output logic        ocrdwe,         // bit  6  8-bit colour RAM, 0
	output logic        ovrdtack,       // bit  5  video-RAM writes wait, 0
	output logic        ocrdtack,       // bit  4  colour-RAM writes wait, 1
	output logic        opium,          // bit 14  playfield 2 enabled, 1
	output logic        opfhsiz_pf2at,  // bit 15  PF2 attribute -1, 0

	// ---- the master enables ----------------------------------------------
	output logic        vad_enable,     // reg 00 bit 15
	output logic        dma_enable,     // reg 00 bit 15 & !bit 14

	// ---- the scanline interrupt ------------------------------------------
	output logic        irq_arm,        // any write to reg 03
	output logic        irq_ack         // any write to reg 1E
);

	// =====================================================================
	// The shadow file
	// =====================================================================
	logic [15:0] regs [0:31];

	assign reg_enable = regs[5'h00];
	assign reg_vsy    = regs[5'h01];
	assign reg_vbl    = regs[5'h02];
	assign reg_vint   = regs[5'h03];
	assign reg_hsy    = regs[5'h04];
	assign reg_hbl    = regs[5'h05];
	assign reg_slip   = regs[5'h06];
	assign reg_apdma  = regs[5'h07];
	assign reg_pmbase = regs[5'h08];
	assign reg_albase = regs[5'h09];
	assign reg_opt    = regs[5'h0A];
	assign reg_mocon  = regs[5'h10];
	assign reg_pcon   = regs[5'h11];
	assign reg_grcon  = regs[5'h12];

	assign vad_enable = reg_enable[15];
	assign dma_enable = HONOUR_ENABLE14 ? (reg_enable[15] & ~reg_enable[14])
	                                    : reg_enable[15];
	assign oas_en     = reg_opt[7];

	// Reg 0A options.  Batman's steady value is 0x4410 (OPIUM, O_DCDMA,
	// OCRDTACK); the game's tile blitters toggle OAS_EN at run time.
	assign opfhsiz_pf2at = reg_opt[15];
	assign opium         = reg_opt[14];
	assign ols_en        = reg_opt[13];
	assign oslpink       = reg_opt[12];
	assign osloram       = reg_opt[11];
	assign o_dcdma       = reg_opt[10];
	assign o_dvdma       = reg_opt[9];
	assign oadroen       = reg_opt[8];
	assign ocrdwe        = reg_opt[6];
	assign ovrdtack      = reg_opt[5];
	assign ocrdtack      = reg_opt[4];

	// =====================================================================
	// The EOF reload sequencer state (runs in VBLANK, not at line 0)
	// =====================================================================
	typedef enum logic [1:0] { EOF_IDLE, EOF_READ, EOF_WAIT } eof_state_t;
	eof_state_t eof_st;
	logic [5:0] eof_i;

	// =====================================================================
	// One write port into the file: CPU or EOF reload
	// =====================================================================
	logic        wr;
	logic  [4:0] wr_a;
	logic [15:0] wr_d;

	wire cpu_wr = cpu_cs & cpu_we;

	// Kept outside the always_comb: Icarus does not support constant part
	// selects inside always_* processes.
	wire [4:0] eof_i_lo = eof_i[4:0];

	always_comb begin
		if (cpu_wr) begin
			wr   = 1'b1;
			wr_a = cpu_a;
			wr_d = cpu_din;
		end else if ((eof_st == EOF_WAIT) && eof_ack
		             && (!EOF_SKIP_ZERO || (eof_data != 16'h0000))) begin
			wr   = 1'b1;
			wr_a = eof_i_lo;
			wr_d = eof_data;
		end else begin
			wr   = 1'b0;
			wr_a = 5'd0;
			wr_d = 16'd0;
		end
	end

	// =====================================================================
	// The parameter-word decoder: one decoder, any source
	// =====================================================================
	wire        par_word = (wr & (wr_a >= 5'h10) & (wr_a <= 5'h1B)) | ls_wr;
	wire [15:0] par_src  = ls_wr ? ls_d : wr_d;
	wire [3:0]  par_tag  = par_src[3:0];
	wire [8:0]  par_val  = par_src[15:7];

	always_ff @(posedge clk) begin
		if (reset) begin
			mo_xscroll      <= 9'd0;
			pf1_xscroll     <= 9'd0;
			pf2_xscroll_raw <= 9'd0;
			mo_yscroll      <= 9'd0;
			pf1_yscroll     <= 9'd0;
			pf2_yscroll     <= 9'd0;
		end else if (par_word) begin
			case (par_tag)
				4'h9: mo_xscroll      <= par_val;
				4'hA: pf1_xscroll     <= par_val;
				4'hB: pf2_xscroll_raw <= par_val;
				4'hD: mo_yscroll      <= par_val;
				4'hE: pf1_yscroll     <= par_val;
				4'hF: pf2_yscroll     <= par_val;
				default: ;   // tags 0-8 and C have no destination
			endcase
		end
	end

	// The two playfields share one horizontal fetch pipeline, so PF2's scroll
	// includes the low three bits of PF1's (confirmed against MAME's frames).
	// Per-layer pixel offsets are applied in batman_pf, not here.
	assign pf2_xscroll = pf2_xscroll_raw
	                   + (COUPLE_FINE ? {6'd0, pf1_xscroll[2:0]} : 9'd0);

	// =====================================================================
	// The file itself
	// =====================================================================
	integer k;
	always_ff @(posedge clk) begin
		if (reset) begin
			for (k = 0; k < 32; k = k + 1) regs[k] <= 16'h0000;
		end else if (wr) begin
			regs[wr_a] <= wr_d;
		end
	end

	// The attribute latches are plain registers (no double buffering seen).
	assign pf1_attr_latch = regs[5'h1C][15:8];   // reg 1C, high lane
	assign pf2_attr_latch = regs[5'h1D][7:0];    // reg 1D, low lane

	// /MOBWR: a CPU or EOF write to 0x10-0x12 is passed on to the MOB, which
	// stores it but does not interpret it (the bit meanings are undocumented).
	assign mob_wr  = wr & (wr_a >= 5'h10) & (wr_a <= 5'h12);
	assign mob_sel = wr_a[1:0];

	// Reg 03 arms the scanline comparator; any write to reg 1E acknowledges
	// the interrupt (the data is ignored).
	assign irq_arm = wr & (wr_a == 5'h03);
	assign irq_ack = wr & (wr_a == 5'h1E);

	// =====================================================================
	// The EOF sequencer
	// =====================================================================
	localparam logic [5:0] EOFLAST = EOF_LAST[5:0];

	always_ff @(posedge clk) begin
		if (reset) begin
			eof_st  <= EOF_IDLE;
			eof_i   <= 6'd0;
			eof_req <= 1'b0;
		end else begin
			case (eof_st)
				EOF_IDLE: begin
					eof_req <= 1'b0;
					if (vblank_start && dma_enable) begin
						eof_i  <= 6'd0;
						eof_st <= EOF_READ;
					end
				end
				EOF_READ: begin
					// A CPU write wins the file's write port, so hold off.
					if (!cpu_wr) begin
						eof_req <= 1'b1;
						eof_st  <= EOF_WAIT;
					end
				end
				EOF_WAIT: begin
					// A CPU write owns the single write port, so an ack in
					// the same cycle is held rather than dropped.
					if (eof_ack && !cpu_wr) begin
						eof_req <= 1'b0;
						if (eof_i == EOFLAST) eof_st <= EOF_IDLE;
						else begin
							eof_i  <= eof_i + 6'd1;
							eof_st <= EOF_READ;
						end
					end
				end
				default: eof_st <= EOF_IDLE;
			endcase
		end
	end
	assign eof_idx = eof_i;

	// =====================================================================
	// Readback
	// =====================================================================
	// Reg 00 reads the beam: vpos clamped to 255, | 0x4000 in vertical blanking.
	wire [7:0]  vclamp = vpos[8] ? 8'hFF : vpos[7:0];
	wire [15:0] beam   = {1'b0, vblank, 6'b0, vclamp};

	always_comb begin
		if (cpu_a == 5'h00)          cpu_dout = beam;
		else if (READBACK_SHADOW)    cpu_dout = regs[cpu_a];
		else                         cpu_dout = 16'h0000;
	end

	/* verilator lint_off UNUSEDSIGNAL */
	// Bits 6-4 of a parameter word are unused by the format.
	wire _unused = &{1'b0, regs[5'h1C][7:0], regs[5'h1D][15:8],
	                 par_src[6:4], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
