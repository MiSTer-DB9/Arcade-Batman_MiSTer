// Adapted for Batman from the Skull & Crossbones core's rtl/video/skullxbo_gfx_client.sv (GPL-3.0); see NOTICE.md
`timescale 1ns/1ps
//============================================================================
//  Graphics-ROM fetch adapter: one hardware stamp fetch is one SDRAM
//  transaction, and the bytes are picked out of the group it returns.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//
//  MiSTer-only: on the board every plane ROM of a layer is read in parallel
//  from one address.  Here the graphics ROMs sit in SDRAM, and
//  batman_rom_loader reorders them during download so that the four plane
//  bytes of one 8-pixel stamp row lie in one aligned 8-byte group (at stride
//  2).  The playfields and motion objects ask for "the stamp row at this byte
//  address"; this module issues one request and assembles lane k from group
//  byte base + k * STRIDE.
//
//  Memory port: `req` is a level held with `addr` until `ack`, a one-clock
//  pulse during which `group` (the arbiter's whole aligned row buffer) is
//  valid.  `late` flags a fetch requested while one was still outstanding;
//  that fetch is dropped, and the video block reports it as `gfx_late`.
//============================================================================

module batman_gfx_client #(
	parameter int AW     = 22,         // the arbiter's byte-address width
	parameter int GROUP  = 16,         // the arbiter's group size, in bytes
	parameter int BEATS  = 2,          // bytes this fetch takes from the group
	parameter int STRIDE = 2           // the step between them inside the group
)(
	input  logic          clk,
	input  logic          reset,

	// ---- video side -------------------------------------------------------
	input  logic          fetch,        // one clk pulse: start a fetch
	input  logic [AW-1:0] fetch_addr,   // byte address of lane 0
	output logic [8*BEATS-1:0] data,    // the assembled plane bytes, held
	output logic          data_valid,   // a whole group has arrived
	output logic          late,         // a fetch arrived with one outstanding

	// ---- memory side ------------------------------------------------------
	output logic          req,          // level, held with the address
	output logic [AW-1:0] addr,         // byte offset inside this region
	output logic [3:0]    blen,         // fetch width in bytes, = BEATS
	input  logic          ack,          // one-clk pulse; `group` valid in it
	input  logic [8*GROUP-1:0] group    // the whole aligned group
);

	localparam int GB = $clog2(GROUP);   // byte index inside the group

	logic [8*BEATS-1:0] data_r;
	logic               busy;
	logic [GB-1:0]      base;

	assign data = data_r;
	assign blen = BEATS[3:0];

	// Lane k is group byte `base + k*STRIDE`.  The loader's reordering keeps
	// every lane of a fetch in one group; the modulo is only a safeguard.
	logic [8*BEATS-1:0] pick;
	always_comb begin
		pick = '0;
		for (int k = 0; k < BEATS; k++)
			pick[8*k +: 8] = group[8*((int'(base) + k*STRIDE) % GROUP) +: 8];
	end

	always_ff @(posedge clk) begin
		late <= 1'b0;
		if (reset) begin
			req        <= 1'b0;
			addr       <= '0;
			base       <= '0;
			busy       <= 1'b0;
			data_r     <= '0;
			data_valid <= 1'b0;
		end else begin
			// A fetch while one is outstanding is dropped (the address must not
			// change mid-transaction) and reported on `late`.
			if (fetch) begin
				data_valid <= 1'b0;
				if (busy) late <= 1'b1;
			end

			if (busy) begin
				if (req && ack) begin
					req        <= 1'b0;
					busy       <= 1'b0;
					data_valid <= 1'b1;
					data_r     <= pick;
				end
			end else if (fetch) begin
				busy <= 1'b1;
				addr <= fetch_addr;
				base <= fetch_addr[GB-1:0];
				req  <= 1'b1;
			end
		end
	end

endmodule
