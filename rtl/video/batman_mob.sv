`timescale 1ns/1ps
//============================================================================
//  Batman motion-object engine: the MOB 137593-001 custom at 10F.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//  Structure follows skullxbo_mob.sv and skullxbo_mo_fetch.sv of the Skull &
//  Crossbones MiSTer core (GPL-3.0), which uses the same custom; see NOTICE.md.
//  The manual lacks the video sheets, so Batman's settings follow MAME's
//  atarimo configuration: 10-bit links, 4-word entries at MOBASE + 4 * link,
//  8 x 8 stamps, a 64-word SLIP table of 8-line bands, no vertical flip.
//
//  Each line (rendered one line ahead, into the bank not being displayed):
//  read the SLIP entry for the band to get the head link, then for each entry
//  read word 3 (Y, width, height), and only if the line hits the object words
//  1 (code, HFLIP) and 2 (X, priority, colour); word 0 (next link) always.  A
//  self-link ends the list.  Each word is a video-RAM request held until
//  batman_vram grants an MO slot, so the bus paces the walk.  For every tile
//  the stamp row is fetched from SDRAM and its 8 pixels written to the line
//  buffer.  MPR2 objects are written too (they still take up line-buffer
//  space); the mixer hides them.
//============================================================================

module batman_mob #(
	// X offset; MAME uses -1.  Kept separate from the X field so it can be
	// tuned against the blanking phase (batman_video sets it).
	parameter int MO_XOFF        = -1,
	// Video-RAM words the walk may spend per line.  456 means no limit beyond
	// the bus slots themselves.
	parameter int MO_WORD_BUDGET = 456,
	// MAME's bitmap geometry, used by the coordinate folds.
	parameter int BITMAP_W       = 456,
	parameter int BITMAP_H       = 262,
	parameter int SLIP_SHIFT     = 3     // 8 scanlines per SLIP band
)(
	input  logic        clk,
	input  logic        reset,

	// ---- one pulse per line, with the line to render ---------------------
	// (line N+1 is rendered during line N; the caller adds the one.)
	input  logic        line_start,
	input  logic  [8:0] vline,

	input  logic  [8:0] xscroll,
	input  logic  [8:0] yscroll,
	input  logic [14:0] base_mo,      // MOBASE, as a word index
	input  logic [14:0] base_slip,    // SLIPBASE, as a word index

	// ---- the scheduled video-RAM port: req held, ack is a one-clk pulse ---
	output logic [14:0] vram_a,
	output logic        vram_rd,
	input  logic        vram_ack,
	input  logic [15:0] vram_q,       // valid in the ack cycle

	// ---- the stamp ROM: one aligned plane group per (code, row) ----------
	output logic        rom_fetch,
	output logic [19:0] rom_addr,
	input  logic [31:0] rom_group,    // {plane3, plane2, plane1, plane0}
	input  logic        rom_valid,

	// ---- the line-buffer write side --------------------------------------
	output logic        lb_we,
	output logic  [9:0] lb_a,
	output logic [10:0] lb_d,         // {MPR2:0, MPAL3:0, MPX3:0} active high

	// ---- status, for debugging --------------------------------------------
	output logic        busy,
	output logic [10:0] words,        // video-RAM words this line has spent
	output logic        budget_hit,   // the walk was cut short
	output logic        line_over     // the walk was still running at line end
);

	typedef enum logic [3:0] {
		S_IDLE, S_SLIP, S_E3, S_E1, S_E2,
		S_TILE, S_ROMREQ, S_ROMHOLD, S_ROMWAIT, S_PIX, S_E0, S_DONE
	} state_t;

	state_t st;

	logic  [5:0] band;
	logic  [9:0] link;
	logic [14:0] code;
	logic        hflip;
	logic  [3:0] width;               // 1..8 tiles across
	logic  [2:0] ty, row;
	logic  [3:0] j;                   // screen tile index, 0..width-1
	logic  [2:0] px;
	logic  [9:0] sx0;                 // this object's left edge, 10-bit wrap
	logic  [2:0] mpr;
	logic  [3:0] mcol;
	logic [31:0] rq;

	// ---------------------------------------------------------------------
	// Vertical match, in MAME's arithmetic so the wrap-around folds agree
	// ---------------------------------------------------------------------
	// ypos = (-Y - yscroll - 8*height) mod 512, folded below the bitmap height
	wire  [8:0] yfield   = vram_q[15:7];
	wire  [3:0] h_next   = {1'b0, vram_q[2:0]} + 4'd1;   // MAME masks 0x0007
	wire  [3:0] w_next   = {1'b0, vram_q[6:4]} + 4'd1;
	wire  [8:0] ypos_mod = 9'd0 - yfield - yscroll - {2'd0, h_next, 3'd0};
	wire signed [10:0] ypos_true =
		(ypos_mod >= BITMAP_H[8:0]) ? ($signed({2'b00, ypos_mod}) - 11'sd512)
		                            :  $signed({2'b00, ypos_mod});
	wire signed [10:0] dv = $signed({2'b00, vline}) - ypos_true;
	wire signed [10:0] vext = $signed({4'd0, h_next, 3'd0});
	wire        vmatch = (dv >= 0) && (dv < vext);

	// the horizontal fold, on word 2
	wire  [8:0] xfield   = vram_q[15:7];
	wire  [8:0] xpos_mod = xfield + MO_XOFF[8:0] - xscroll;
	wire  [9:0] xpos_lb  = (xpos_mod >= BITMAP_W[8:0]) ? ({1'b0, xpos_mod} + 10'd512)
	                                                   :  {1'b0, xpos_mod};

	// the stamp for the tile now being fetched
	wire  [3:0] kcode = hflip ? (width - 4'd1 - j) : j;
	wire  [6:0] tyw   = {4'd0, ty} * {3'd0, width};   // <= 7 * 8 = 56
	wire [14:0] stamp = code + {8'd0, tyw} + {11'd0, kcode};

	// the pixel inside the stamp: bit `bsel` of each plane byte, MSB left
	wire  [2:0] bsel  = hflip ? px : (3'd7 - px);
	wire  [3:0] pen_n = {rq[{2'd3, bsel}], rq[{2'd2, bsel}],
	                     rq[{2'd1, bsel}], rq[{2'd0, bsel}]};

	wire over_budget = (words >= MO_WORD_BUDGET[10:0]);

	// band = ((y + yscroll) mod 512) >> 3; a 9-bit wire so the sum wraps at 512.
	wire  [8:0] bsum = vline + yscroll;

	// Stamp fetch address: the 8-byte SDRAM group per (code, row pair) holds
	// plane p of row r at byte (r & 1) + 2p (the loader's reordering).
	assign rom_addr = {stamp, row[2:1], 2'b00, row[0]};

	always_comb begin
		vram_a  = 15'd0;
		vram_rd = 1'b0;
		case (st)
			S_SLIP: begin vram_a = base_slip + {9'd0, band};      vram_rd = 1'b1; end
			S_E3:   begin vram_a = base_mo + {3'd0, link, 2'b11}; vram_rd = 1'b1; end
			S_E1:   begin vram_a = base_mo + {3'd0, link, 2'b01}; vram_rd = 1'b1; end
			S_E2:   begin vram_a = base_mo + {3'd0, link, 2'b10}; vram_rd = 1'b1; end
			S_E0:   begin vram_a = base_mo + {3'd0, link, 2'b00}; vram_rd = 1'b1; end
			default:  ;
		endcase
	end

	assign busy  = (st != S_IDLE) && (st != S_DONE);

	always_ff @(posedge clk) begin
		if (reset) begin
			st         <= S_IDLE;
			lb_we      <= 1'b0;
			words      <= 11'd0;
			budget_hit <= 1'b0;
			line_over  <= 1'b0;
			rom_fetch  <= 1'b0;
		end else begin
			lb_we     <= 1'b0;
			rom_fetch <= 1'b0;

			if (line_start) begin
				// The SLIP band scrolls with the objects.
				band       <= bsum[8:SLIP_SHIFT];
				words      <= 11'd0;
				budget_hit <= 1'b0;
				if (busy) line_over <= 1'b1;
				st         <= S_SLIP;
			end else begin
				case (st)
					// ---- the head link ---------------------------------
					S_SLIP: if (vram_ack) begin
						words <= words + 11'd1;
						link  <= vram_q[9:0];
						st    <= S_E3;
					end

					// ---- word 3: Y, width, height ----------------------
					S_E3: begin
						if (over_budget) begin
							budget_hit <= 1'b1;
							st         <= S_DONE;
						end else if (vram_ack) begin
							words  <= words + 11'd1;
							width  <= w_next;
							ty     <= dv[5:3];
							row    <= dv[2:0];
							st     <= vmatch ? S_E1 : S_E0;
						end
					end

					// ---- word 1: stamp code and HFLIP ------------------
					S_E1: if (vram_ack) begin
						words <= words + 11'd1;
						code  <= vram_q[14:0];
						hflip <= vram_q[15];
						st    <= S_E2;
					end

					// ---- word 2: X, priority, colour -------------------
					S_E2: if (vram_ack) begin
						words <= words + 11'd1;
						sx0   <= xpos_lb;
						mpr   <= vram_q[6:4];
						mcol  <= vram_q[3:0];
						j     <= 4'd0;
						st    <= S_TILE;
					end

					// ---- the tiles -------------------------------------
					S_TILE: st <= (j < width) ? S_ROMREQ : S_E0;
					S_ROMREQ: begin
						rom_fetch <= 1'b1;
						st        <= S_ROMHOLD;
					end
					// batman_gfx_client holds `data_valid` from the previous
					// fetch until it sees this `fetch` pulse; wait one cycle so
					// the previous stamp's data is not taken.
					S_ROMHOLD: st <= S_ROMWAIT;
					S_ROMWAIT: if (rom_valid) begin
						rq <= rom_group;
						px <= 3'd0;
						st <= S_PIX;
					end
					S_PIX:  begin
						lb_we <= 1'b1;
						lb_a  <= sx0 + {3'd0, j, 3'd0} + {7'd0, px};
						lb_d  <= {mpr, mcol, ~pen_n};
						px    <= px + 3'd1;
						if (px == 3'd7) begin j <= j + 4'd1; st <= S_TILE; end
					end

					// ---- word 0: the next link -------------------------
					S_E0: begin
						if (over_budget) begin
							budget_hit <= 1'b1;
							st         <= S_DONE;
						end else if (vram_ack) begin
							words <= words + 11'd1;
							// The list ends on a self-link.
							if (vram_q[9:0] == link) st <= S_DONE;
							else begin link <= vram_q[9:0]; st <= S_E3; end
						end
					end

					S_IDLE, S_DONE: ;        // parked until the next line
					default: st <= S_DONE;
				endcase
			end
		end
	end

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, ypos_true[10], dv[10:6], bsum[2:0], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
