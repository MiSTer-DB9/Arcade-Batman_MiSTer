// Adapted for Batman from the Skull & Crossbones core's rtl/mem/skullxbo_sdram_loader.sv (GPL-3.0); see NOTICE.md
`timescale 1ns/1ps
//============================================================================
//  Batman SDRAM loader-writer (MiSTer only): packs the download byte stream
//  into 16-bit words and writes them through the batman_gfx_mem write port.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Ported from the Badlands MiSTer
//  core (GPL-3.0, same author; itself from Blasteroids / Xybots / Toobin').
//
//  Word address = byte address >> 1.  The even byte goes to D15:8 and the odd
//  byte to D7:0, so the 68000 reads SDRAM words unchanged.  The even byte is
//  latched and the word written on the odd byte.  `wr_busy` must drive
//  ioctl_wait so the stream can never outrun the SDRAM.  This is the only
//  SDRAM write path; it goes through the arbiter's own write port.
//============================================================================

module batman_sdram_loader #(
	parameter int AW = 24
)(
	input  logic          clk,
	input  logic          reset,

	// ---- byte stream from batman_rom_loader (SDRAM regions only) ----
	input  logic          ld_wr,
	input  logic [23:0]   ld_addr,        // SDRAM BYTE address
	input  logic  [7:0]   ld_data,
	output logic          wr_busy,        // -> ioctl_wait (back-pressure)

	// ---- gfx_mem write port ----
	output logic          dl_wr,
	output logic [AW-1:0] dl_waddr,       // SDRAM WORD address
	output logic [15:0]   dl_wdata,
	input  logic          dl_ack
);

	wire any_ev = ld_wr && !ld_addr[0];   // the even (first) byte of a word
	wire any_od = ld_wr &&  ld_addr[0];   // the word-completing (odd) byte

	logic [7:0] hi_buf;                   // the latched even byte -> D15:8

	wire [AW-1:0] word_addr = AW'(ld_addr[23:1]);
	wire [15:0]   word_data = {hi_buf, ld_data};   // even -> D15:8, odd -> D7:0

	typedef enum logic [0:0] { L_IDLE, L_WR } lstate_t;
	lstate_t st;

	// busy while writing, and in the cycle a word completes
	assign wr_busy = (st == L_WR) || (st == L_IDLE && any_od);

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= L_IDLE; dl_wr <= 1'b0;
		end else begin
			// Latch the even byte in any state, so an early even byte can
			// never pair with a stale one (wr_busy normally prevents this).
			if (any_ev) hi_buf <= ld_data;
			case (st)
				L_IDLE: begin
					dl_wr <= 1'b0;
					if (any_od) begin
						dl_waddr <= word_addr;
						dl_wdata <= word_data;
						dl_wr    <= 1'b1;
						st       <= L_WR;
					end
				end
				L_WR: begin
					if (dl_ack) begin dl_wr <= 1'b0; st <= L_IDLE; end
				end
				default: st <= L_IDLE;
			endcase
		end
	end

	// Simulation-only check: an odd byte arriving while a word is still
	// outstanding means ioctl_wait is not wired to wr_busy.
`ifndef ALTERA_RESERVED_QIS
	always @(posedge clk)
		if (!reset && st == L_WR && any_od)
			$display("ERROR: batman_sdram_loader overrun - a word-completing byte arrived while a write was outstanding; ioctl_wait is not wired to wr_busy");
`endif

endmodule
