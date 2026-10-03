// Adapted for Batman from the Skull & Crossbones core's rtl/mem/skullxbo_prog_rom.sv (GPL-3.0); see NOTICE.md
`timescale 1ns/1ps
//============================================================================
//  Batman 68000 program ROM: the six 27C010s at 10R/7R, 9-10R/6R and 9R/5R
//  (schematic page 45), served from SDRAM through a direct-mapped cache with
//  4-word lines and next-line prefetch.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Structure follows the Skull &
//  Crossbones MiSTer core (GPL-3.0, itself from Vindicators); see NOTICE.md.
//
//  The 768 KB program is too big for block RAM, so it lives in SDRAM.  A hit
//  answers in one clk_sys; a miss raises `stall`, which batman_main uses to
//  hold off /DTACK (extra wait states; the real ROM always answers in five
//  CPU clocks).  The CPU clock itself is never stretched, so it stays locked
//  to the VAD.  0x0C0000-0x0FFFFF is undecoded on the board and needs no
//  special case.  There is no SLAPSTIC.
//
//  LINES sets of 4 words (default 2048 = 16 KB, 20 M10K).  The tag RAM is
//  kept as two copies so the current and the next set can be checked in one
//  cycle for the prefetch.  Block-RAM hazards: reads colliding with a tag
//  write are forced to miss for one cycle (`blk`); `reset` starts a walk that
//  invalidates every set before the 68000 leaves reset; array reads stay
//  plain `q <= mem[addr]` so Quartus infers M10K.
//============================================================================

module batman_prog_rom #(
	parameter int AW = 24,
	// WORD address of the program ROM inside SDRAM
	parameter logic [AW-1:0] PROG_BASE = 24'h000000,
	// 768 KB = 0x60000 words at 0x000000-0x0BFFFF, addressed by A19..A1.
	parameter int PAW        = 19,
	parameter int PROG_WORDS = 'h60000,     // 768 KB = 384 K words
	parameter int LINES      = 2048         // sets; each is 4 words
)(
	input  logic          clk,
	input  logic          reset,            // init_reset | ~rom_loaded

	// ---- 68000 side ----
	input  logic          rd,               // /ROMn asserted on a READ
	input  logic [PAW-1:0] addr,            // the 68000's A19..A1
	output logic [15:0]   data,             // valid 1 clk_sys after addr ON A HIT
	output logic          ready,            // `data` belongs to the current addr
	output logic          stall,            // rd & ~ready: hold /DTACK off

	// ---- batman_gfx_mem CPU read port ----
	output logic          c_req,
	output logic [AW-1:0] c_addr,
	output logic  [1:0]   c_blen,
	input  logic          c_valid,
	input  logic          c_last,
	input  logic [15:0]   c_rdata
);

	localparam int LINE_WORDS = 4;
	localparam int OFF_BITS   = 2;                        // $clog2(LINE_WORDS)
	localparam int IDX_BITS   = $clog2(LINES);
	localparam int LINE_BITS  = PAW - OFF_BITS;           // the address of a line
	localparam int TAG_BITS   = LINE_BITS - IDX_BITS;
	localparam int TW         = TAG_BITS + 1;             // {valid, tag}
	localparam int DAW        = IDX_BITS + OFF_BITS;      // data-array address
	// The first line past the end of the ROM.  If the ROM filled the whole word
	// space that line number would not fit in LINE_BITS and would wrap to 0,
	// silently disabling the prefetch; FULL_SPACE handles that case.
	localparam int LINES_TOTAL = PROG_WORDS / LINE_WORDS;
	localparam bit FULL_SPACE  = (LINES_TOTAL >= (1 << LINE_BITS));

	assign c_blen = 2'(LINE_WORDS - 1);

	// ==== storage ==========================================================
	(* ramstyle = "no_rw_check, M10K" *) logic [15:0]   dmem [0:LINES*LINE_WORDS-1];
	(* ramstyle = "no_rw_check, M10K" *) logic [TW-1:0] tmem_a [0:LINES-1];
	(* ramstyle = "no_rw_check, M10K" *) logic [TW-1:0] tmem_b [0:LINES-1];

	// ==== stage 0: the lookup addresses, straight off `addr` ===============
	wire [IDX_BITS-1:0] cur_idx = addr[IDX_BITS+OFF_BITS-1:OFF_BITS];
	wire [OFF_BITS-1:0] cur_off = addr[OFF_BITS-1:0];
	wire [IDX_BITS-1:0] pf_idx  = cur_idx + 1'b1;

	logic [PAW-1:0] addr_r;
	logic        rd_r;
	always_ff @(posedge clk) begin
		addr_r <= addr;
		rd_r   <= rd;
	end

	// ==== stage 1: what the registered arrays are describing ===============
	wire [LINE_BITS-1:0] s_line = addr_r[PAW-1:OFF_BITS];
	wire [IDX_BITS-1:0]  s_idx  = s_line[IDX_BITS-1:0];
	wire [TAG_BITS-1:0]  s_tag  = s_line[LINE_BITS-1:IDX_BITS];
	wire [LINE_BITS-1:0] n_line = s_line + 1'b1;
	wire [IDX_BITS-1:0]  n_idx  = n_line[IDX_BITS-1:0];
	wire [TAG_BITS-1:0]  n_tag  = n_line[LINE_BITS-1:IDX_BITS];
	wire                 n_in_rom = FULL_SPACE ? (n_line != '0)
	                                           : (n_line < LINE_BITS'(LINES_TOTAL));

	// ==== the write ports (driven combinationally from the fill engine) ====
	logic                dw_we;
	logic [DAW-1:0]      dw_addr;
	logic                tw_we;
	logic [IDX_BITS-1:0] tw_idx;
	logic [TW-1:0]       tw_data;

	logic [15:0]   d_q;
	logic [TW-1:0] t_cur, t_nxt;

	always_ff @(posedge clk) begin
		if (dw_we) dmem[dw_addr] <= c_rdata;
		d_q <= dmem[{cur_idx, cur_off}];
		if (tw_we) tmem_a[tw_idx] <= tw_data;
		if (tw_we) tmem_b[tw_idx] <= tw_data;
		t_cur <= tmem_a[cur_idx];
		t_nxt <= tmem_b[pf_idx];
	end

	// ---- read-during-write guard -----------------------------------------
	logic                tw_en_q;
	logic [IDX_BITS-1:0] tw_idx_q;
	always_ff @(posedge clk) begin
		tw_en_q  <= tw_we;
		tw_idx_q <= tw_idx;
	end
	wire blk = tw_en_q && (tw_idx_q == s_idx);

	// ==== the invalidate walk ==============================================
	// Starts at power-up and on every rising edge of `reset`, so a new ROM
	// download never leaves a stale line.
	logic                clr_run;
	logic [IDX_BITS-1:0] clr_idx;
	logic                reset_q;
	// `initial` sets the power-up value; reset_q = 0 makes a `reset` that is
	// already high at power-up look like a rising edge on the first clock.
	initial begin
		clr_run = 1'b1;
		clr_idx = '0;
		reset_q = 1'b0;
	end
	// Plain `always`: an always_ff variable may not also be written by `initial`.
	always @(posedge clk) begin
		reset_q <= reset;
		if (reset && !reset_q) begin
			clr_run <= 1'b1;
			clr_idx <= '0;
		end else if (clr_run) begin
			clr_idx <= clr_idx + 1'b1;
			if (clr_idx == IDX_BITS'(LINES-1)) clr_run <= 1'b0;
		end
	end

	// ==== the tag compare ==================================================
	wire hit       = t_cur[TW-1] && (t_cur[TAG_BITS-1:0] == s_tag) && !blk && !clr_run;
	wire n_present = t_nxt[TW-1] && (t_nxt[TAG_BITS-1:0] == n_tag);

	assign data  = d_q;
	assign ready = hit && (addr_r == addr);
	assign stall = rd & ~ready;

	// ==== fill engine ======================================================
	typedef enum logic [1:0] { F_IDLE, F_REQ, F_FILL, F_SETTLE } fstate_t;
	fstate_t st;

	logic [IDX_BITS-1:0] f_idx;
	logic [TAG_BITS-1:0] f_tag;
	logic [OFF_BITS-1:0] f_off;

	// Demand fill: the address the CPU is still holding missed.
	// Prefetch: it hit and the next line is absent.
	wire miss_now = rd_r && (addr_r == addr) && !hit && !blk && !clr_run;
	wire want_pf  = rd_r && hit && !n_present && n_in_rom && !clr_run;

	wire do_dem = (st == F_IDLE) && miss_now;
	wire do_pf  = (st == F_IDLE) && !miss_now && want_pf;
	wire fill_start = do_dem | do_pf;
	wire fill_done  = (st == F_FILL) && c_valid && c_last;

	wire [LINE_BITS-1:0] start_line = do_dem ? s_line : n_line;
	wire [IDX_BITS-1:0]  start_idx  = do_dem ? s_idx  : n_idx;
	wire [TAG_BITS-1:0]  start_tag  = do_dem ? s_tag  : n_tag;

	always_comb begin
		// data: one word per burst beat
		dw_we   = (st == F_FILL) && c_valid;
		dw_addr = {f_idx, f_off};

		// tags: the walk clears every set; a starting fill invalidates its
		// victim; a completing fill validates it with its new tag.
		tw_we   = 1'b0;
		tw_idx  = clr_idx;
		tw_data = '0;
		if (clr_run) begin
			tw_we   = 1'b1;
			tw_idx  = clr_idx;
			tw_data = '0;                       // valid = 0
		end else if (fill_start) begin
			tw_we   = 1'b1;
			tw_idx  = start_idx;
			tw_data = '0;
		end else if (fill_done) begin
			tw_we   = 1'b1;
			tw_idx  = f_idx;
			tw_data = {1'b1, f_tag};
		end
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= F_IDLE; c_req <= 1'b0; f_off <= '0;
			f_idx <= '0; f_tag <= '0;
		end else begin
			case (st)
				F_IDLE: begin
					f_off <= '0;
					if (fill_start) begin
						c_addr <= PROG_BASE + AW'({start_line, {OFF_BITS{1'b0}}});
						f_idx  <= start_idx;
						f_tag  <= start_tag;
						c_req  <= 1'b1;
						st     <= F_REQ;
					end
				end
				// hold c_req until the burst's last word (arbiter protocol)
				F_REQ: st <= F_FILL;
				F_FILL: begin
					if (c_valid) begin
						f_off <= f_off + 1'b1;
						if (c_last) begin
							c_req <= 1'b0;
							st    <= F_SETTLE;
						end
					end
				end
				// one dead cycle so the tag read pipeline sees the completed write
				F_SETTLE: st <= F_IDLE;
				default: st <= F_IDLE;
			endcase
		end
	end

endmodule
