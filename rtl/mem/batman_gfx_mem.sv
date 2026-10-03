// Adapted for Batman from the Skull & Crossbones core's rtl/mem/skullxbo_gfx_mem.sv (GPL-3.0); see NOTICE.md
`timescale 1ns/1ps
//============================================================================
//  Batman SDRAM client arbiter (MiSTer only): the 68000 program-ROM word
//  client, two playfield and one motion-object graphics byte client, the
//  MSM6295 sample byte client and the ROM download write port, all sharing
//  one batman_sdram controller.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Ported from the Badlands MiSTer
//  core (GPL-3.0, same author; itself from Blasteroids / Xybots / Toobin').
//
//  SDRAM map (byte addresses; each region at its ROM-stream offset):
//    0x000000  768 KB  68000 program       cpu (word client)
//    0x0C0000  128 KB  alpha tiles         written only; read from block RAM
//    0x0E0000    1 MB  playfield tiles     pf1, pf2
//    0x1E0000    1 MB  motion objects      mo
//    0x2E0000   64 KB  JSA 6502 program    written only; read from block RAM
//    0x2F0000  512 KB  MSM6295 samples     oki
//  Each SDRAM word is {even byte, odd byte}: D15:8 holds the even address.
//
//  Byte clients: raise *_req with the address and hold both; *_ack is a
//  one-cycle pulse with *_data (and *_group, the whole fetch group) valid and
//  held until the next ack; drop *_req before the next request.  Each client
//  has a row buffer filled by one burst (8 bytes; 16 for MO), and the loader
//  reorders the graphics ROMs so one hardware fetch is one aligned group.
//  The CPU client asks for a 4-word cache line and gets the words on
//  consecutive cpu_valid pulses, cpu_last on the last.
//
//  Priority: download write > PF1 > PF2 > MO > CPU > OKI.  The graphics
//  clients go first because a late tile fetch is a visible glitch, while a
//  late CPU fetch only adds a 68000 wait state.  Refresh (rfsh_ok) runs when
//  nobody is asking; if it has been deferred RFSH_DEFER_MAX cycles the window
//  is forced open.
//============================================================================

module batman_gfx_mem #(
	parameter int AW = 24,
	// Region word bases.  The loader reorders bytes inside the tile and sprite
	// regions but keeps the region bases.
	parameter logic [AW-1:0] PF_BASE  = 24'h070000,   // byte 0x0E0000, `tiles`
	parameter logic [AW-1:0] MO_BASE  = 24'h0F0000,   // byte 0x1E0000, `sprites`
	// MSM6295 samples: 512 KB at byte 0x2F0000.
	parameter logic [AW-1:0] OKI_BASE = 24'h178000,   // byte 0x2F0000, 512 KB
	// how long a due AUTO_REFRESH may be deferred before the window is forced
	parameter int RFSH_DEFER_MAX = 512
)(
	input  logic          clk,          // clk_sys 57.272727 MHz
	input  logic          reset,

	// ---- 68000 program-ROM word client (batman_prog_rom) ----
	input  logic          cpu_req,
	input  logic [AW-1:0] cpu_addr,     // SDRAM WORD address
	input  logic  [1:0]   cpu_blen,     // words - 1
	output logic          cpu_valid,
	output logic          cpu_last,
	output logic [15:0]   cpu_rdata,

	// ---- playfield 1 byte client ----
	// Two playfield clients: the layers share only the fine scroll, so they
	// fetch different tile columns at the same time.
	input  logic          pf1_req,      // level, HELD with the address
	input  logic [19:0]   pf1_addr,     // BYTE offset inside `tiles`, 0..0xFFFFF
	output logic          pf1_ack,      // ONE-cycle pulse; pf1_data valid in it
	output logic  [7:0]   pf1_data,     // HELD until this client's next ack
	output logic [63:0]   pf1_group,    // the whole 8-byte group, held

	// ---- playfield 2 byte client ----
	input  logic          pf2_req,
	input  logic [19:0]   pf2_addr,
	output logic          pf2_ack,
	output logic  [7:0]   pf2_data,
	output logic [63:0]   pf2_group,

	// ---- motion-object byte client ----
	input  logic          mo_req,
	input  logic [21:0]   mo_addr,      // BYTE offset inside the 1 MB sprite region
	output logic          mo_ack,
	output logic  [7:0]   mo_data,
	output logic [127:0]  mo_group,    // the whole 16-byte stamp group

	// ---- MSM6295 sample byte client ----
	input  logic          oki_req,
	input  logic [18:0]   oki_addr,     // BYTE offset inside the sample ROM, 0..0x7FFFF
	output logic          oki_ack,
	output logic  [7:0]   oki_data,

	// ---- loader write port (WORD address, from batman_sdram_loader) ----
	input  logic          dl_wr,
	input  logic [AW-1:0] dl_waddr,
	input  logic [15:0]   dl_wdata,
	output logic          dl_ack,

	// ---- batman_sdram controller port ----
	output logic          sd_req,
	output logic [AW-1:0] sd_addr,
	output logic          sd_we,
	output logic  [2:0]   sd_blen,
	output logic [15:0]   sd_wdata,
	output logic          rfsh_ok,
	input  logic          sd_ready,
	input  logic          sd_valid,
	input  logic [15:0]   sd_rdata
);

	// ---- row buffers: 8 bytes (burst-4) for PF and OKI, 16 (burst-8) for MO
	logic [15:0] pf1_buf [0:3];   logic [16:0] pf1_tag;  logic pf1_bufv;
	logic [15:0] pf2_buf [0:3];   logic [16:0] pf2_tag;  logic pf2_bufv;
	logic [15:0] mo_buf  [0:7];   logic [17:0] mo_tag;   logic mo_bufv;
	logic [15:0] oki_buf [0:3];   logic [15:0] oki_tag;  logic oki_bufv;

	wire pf1_hit = pf1_bufv && (pf1_tag == pf1_addr[19:3]);
	wire pf2_hit = pf2_bufv && (pf2_tag == pf2_addr[19:3]);
	wire mo_hit  = mo_bufv  && (mo_tag  == mo_addr[21:4]);
	wire oki_hit = oki_bufv && (oki_tag == oki_addr[18:3]);

	// ---- per-client request state ----------------------------------------
	typedef enum logic [1:0] { C_IDLE, C_MISS, C_HOLD } cstate_t;
	cstate_t pf1_st, pf2_st, mo_st, oki_st;

	// Pulsed for one cycle when a fill completes; buffer and tag update on the
	// same edge.
	logic pf1_fill, pf2_fill, mo_fill, oki_fill;

	// ---- the central arbiter / SDRAM sequencer ---------------------------
	typedef enum logic [1:0] { G_IDLE, G_REQ, G_WAIT, G_HOLD } gstate_t;
	gstate_t st;

	typedef enum logic [2:0] { OP_WR, OP_CPU, OP_MO, OP_PF1, OP_PF2, OP_OKI } op_t;
	op_t op;

	logic [2:0]  wcnt;

	wire pf1_need = (pf1_st == C_MISS);
	wire pf2_need = (pf2_st == C_MISS);
	wire mo_need  = (mo_st  == C_MISS);
	wire oki_need = (oki_st == C_MISS);

	// ---- the refresh window, plus its deferral watchdog -------------------
	localparam int DEFER_W = $clog2(RFSH_DEFER_MAX + 1);
	logic [DEFER_W-1:0] defer;
	wire rfsh_win = (st == G_IDLE) && !dl_wr
	             && !cpu_req && !pf1_req && !pf2_req && !mo_req && !oki_req
	             && !pf1_need && !pf2_need && !mo_need && !oki_need;
	assign rfsh_ok = rfsh_win || (defer >= DEFER_W'(RFSH_DEFER_MAX));

	always_ff @(posedge clk) begin
		if (reset)         defer <= '0;
		else if (rfsh_ok)  defer <= '0;
		else if (defer != DEFER_W'(RFSH_DEFER_MAX)) defer <= defer + 1'b1;
	end

	// Fixed priority: PF1, PF2, MO, then the CPU (see the header).
	wire take_pf1 = pf1_need;
	wire take_pf2 = pf2_need && !pf1_need;
	wire take_mo  = mo_need  && !pf1_need && !pf2_need;

	// Each byte client fetches the aligned group its address falls in.
	wire [AW-1:0] pf1_wa = PF_BASE  + {{(AW-19){1'b0}}, pf1_addr[19:3], 2'b00};
	wire [AW-1:0] pf2_wa = PF_BASE  + {{(AW-19){1'b0}}, pf2_addr[19:3], 2'b00};
	wire [AW-1:0] mo_wa  = MO_BASE  + {{(AW-21){1'b0}}, mo_addr[21:4],  3'b000};
	wire [AW-1:0] oki_wa = OKI_BASE + {{(AW-18){1'b0}}, oki_addr[18:3], 2'b00};

	// The tag is latched with the burst address, so a client that moved its
	// address mid-transaction could never mislabel the buffer.
	logic [16:0] pf1_tag_l;
	logic [16:0] pf2_tag_l;
	logic [17:0] mo_tag_l;
	logic [15:0] oki_tag_l;

	logic [2:0] blen_l;
	wire  [2:0] wlast = blen_l;

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= G_IDLE; sd_req <= 1'b0; sd_we <= 1'b0; sd_blen <= 3'd0;
			dl_ack <= 1'b0;
			pf1_fill <= 1'b0; pf2_fill <= 1'b0;
			mo_fill <= 1'b0; oki_fill <= 1'b0;
			pf1_bufv <= 1'b0; pf2_bufv <= 1'b0;
			mo_bufv <= 1'b0; oki_bufv <= 1'b0;
			cpu_valid <= 1'b0; cpu_last <= 1'b0;
			op <= OP_WR; blen_l <= 3'd0;
		end else begin
			dl_ack    <= 1'b0;
			sd_req    <= 1'b0;
			pf1_fill  <= 1'b0;
			pf2_fill  <= 1'b0;
			mo_fill   <= 1'b0;
			oki_fill  <= 1'b0;
			cpu_valid <= 1'b0;
			cpu_last  <= 1'b0;
			case (st)
				// ---- pick a client: write, PF1, PF2, MO, CPU, OKI
				G_IDLE: begin
					wcnt <= 3'd0;
					if (dl_wr) begin
						op <= OP_WR; sd_addr <= dl_waddr; sd_we <= 1'b1;
						sd_blen <= 3'd0; blen_l <= 3'd0; sd_wdata <= dl_wdata;
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end else if (take_pf1) begin
						op <= OP_PF1; sd_addr <= pf1_wa; sd_we <= 1'b0;
						sd_blen <= 3'd3; blen_l <= 3'd3;
						pf1_tag_l <= pf1_addr[19:3];
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end else if (take_pf2) begin
						op <= OP_PF2; sd_addr <= pf2_wa; sd_we <= 1'b0;
						sd_blen <= 3'd3; blen_l <= 3'd3;
						pf2_tag_l <= pf2_addr[19:3];
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end else if (take_mo) begin
						op <= OP_MO; sd_addr <= mo_wa; sd_we <= 1'b0;
						sd_blen <= 3'd7; blen_l <= 3'd7;
						mo_tag_l <= mo_addr[21:4];
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end else if (cpu_req) begin
						op <= OP_CPU; sd_addr <= cpu_addr; sd_we <= 1'b0;
						sd_blen <= {1'b0, cpu_blen}; blen_l <= {1'b0, cpu_blen};
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end else if (oki_need) begin
						op <= OP_OKI; sd_addr <= oki_wa; sd_we <= 1'b0;
						sd_blen <= 3'd3; blen_l <= 3'd3;
						oki_tag_l <= oki_addr[18:3];
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end
				end
				// ---- req asserted for exactly this cycle ----
				G_REQ: begin
					sd_req <= 1'b0; sd_we <= 1'b0;
					st <= G_WAIT;
				end
				// ---- await completion (burst words on consecutive sd_valid) ----
				G_WAIT: begin
					if (op == OP_WR) begin
						if (sd_ready) begin dl_ack <= 1'b1; st <= G_HOLD; end
					end else if (sd_valid) begin
						wcnt <= wcnt + 3'd1;
						case (op)
							OP_CPU: begin
								cpu_rdata <= sd_rdata;
								cpu_valid <= 1'b1;
								if (wcnt == wlast) begin cpu_last <= 1'b1; st <= G_HOLD; end
							end
							OP_MO: begin
								mo_buf[wcnt] <= sd_rdata;
								if (wcnt == wlast) begin
									mo_tag  <= mo_tag_l;
									mo_bufv <= 1'b1;
									mo_fill <= 1'b1;
									st      <= G_HOLD;
								end
							end
							OP_PF1: begin
								pf1_buf[wcnt[1:0]] <= sd_rdata;
								if (wcnt == wlast) begin
									pf1_tag  <= pf1_tag_l;
									pf1_bufv <= 1'b1;
									pf1_fill <= 1'b1;
									st       <= G_HOLD;
								end
							end
							OP_PF2: begin
								pf2_buf[wcnt[1:0]] <= sd_rdata;
								if (wcnt == wlast) begin
									pf2_tag  <= pf2_tag_l;
									pf2_bufv <= 1'b1;
									pf2_fill <= 1'b1;
									st       <= G_HOLD;
								end
							end
							default: begin   // OP_OKI
								oki_buf[wcnt[1:0]] <= sd_rdata;
								if (wcnt == wlast) begin
									oki_tag  <= oki_tag_l;
									oki_bufv <= 1'b1;
									oki_fill <= 1'b1;
									st       <= G_HOLD;
								end
							end
						endcase
					end
				end
				// ---- one transaction per request: wait for the client to drop it
				G_HOLD: begin
					case (op)
						OP_WR:   if (!dl_wr)           st <= G_IDLE;
						OP_CPU:  if (!cpu_req)         st <= G_IDLE;
						OP_MO:   if (mo_st  != C_MISS) st <= G_IDLE;
						OP_PF1:  if (pf1_st != C_MISS) st <= G_IDLE;
						OP_PF2:  if (pf2_st != C_MISS) st <= G_IDLE;
						default: if (oki_st != C_MISS) st <= G_IDLE;   // OP_OKI
					endcase
				end
				default: st <= G_IDLE;
			endcase
		end
	end

	// ---- byte select: even byte address -> D15:8, odd -> D7:0 ------------
	wire [15:0] pf1_w = pf1_buf[pf1_addr[2:1]];
	wire [15:0] pf2_w = pf2_buf[pf2_addr[2:1]];
	wire [15:0] mo_w  = mo_buf [mo_addr[3:1]];
	wire [15:0] oki_w = oki_buf[oki_addr[2:1]];
	wire  [7:0] pf1_b = pf1_addr[0] ? pf1_w[7:0] : pf1_w[15:8];
	wire  [7:0] pf2_b = pf2_addr[0] ? pf2_w[7:0] : pf2_w[15:8];
	wire  [7:0] mo_b  = mo_addr[0]  ? mo_w[7:0]  : mo_w[15:8];
	wire  [7:0] oki_b = oki_addr[0] ? oki_w[7:0] : oki_w[15:8];

	// ---- the whole group, byte i = even lane of word i/2 if i is even, else
	// the odd lane; registered with *_ack and held like *_data.
	wire [63:0] pf1_grp_w = { pf1_buf[3][7:0], pf1_buf[3][15:8],
	                          pf1_buf[2][7:0], pf1_buf[2][15:8],
	                          pf1_buf[1][7:0], pf1_buf[1][15:8],
	                          pf1_buf[0][7:0], pf1_buf[0][15:8] };
	wire [63:0] pf2_grp_w = { pf2_buf[3][7:0], pf2_buf[3][15:8],
	                          pf2_buf[2][7:0], pf2_buf[2][15:8],
	                          pf2_buf[1][7:0], pf2_buf[1][15:8],
	                          pf2_buf[0][7:0], pf2_buf[0][15:8] };
	wire [127:0] mo_grp_w = { mo_buf[7][7:0], mo_buf[7][15:8],
	                          mo_buf[6][7:0], mo_buf[6][15:8],
	                          mo_buf[5][7:0], mo_buf[5][15:8],
	                          mo_buf[4][7:0], mo_buf[4][15:8],
	                          mo_buf[3][7:0], mo_buf[3][15:8],
	                          mo_buf[2][7:0], mo_buf[2][15:8],
	                          mo_buf[1][7:0], mo_buf[1][15:8],
	                          mo_buf[0][7:0], mo_buf[0][15:8] };

	// ---- the four client state machines ----------------------------------
	always_ff @(posedge clk) begin
		if (reset) begin
			pf1_st <= C_IDLE; pf1_ack <= 1'b0; pf1_data <= 8'h00;
			pf2_st <= C_IDLE; pf2_ack <= 1'b0; pf2_data <= 8'h00;
			pf1_group <= 64'd0; pf2_group <= 64'd0; mo_group <= 128'd0;
			mo_st  <= C_IDLE; mo_ack  <= 1'b0; mo_data  <= 8'h00;
			oki_st <= C_IDLE; oki_ack <= 1'b0; oki_data <= 8'h00;
		end else begin
			pf1_ack <= 1'b0;
			pf2_ack <= 1'b0;
			mo_ack  <= 1'b0;
			oki_ack <= 1'b0;

			case (pf1_st)
				C_IDLE: if (pf1_req) begin
					if (pf1_hit) begin
						pf1_data  <= pf1_b;
						pf1_group <= pf1_grp_w;
						pf1_ack   <= 1'b1;
						pf1_st    <= C_HOLD;
					end else pf1_st <= C_MISS;
				end
				C_MISS: if (pf1_fill) begin
					pf1_data  <= pf1_b;
					pf1_group <= pf1_grp_w;
					pf1_ack   <= 1'b1;
					pf1_st    <= C_HOLD;
				end
				default: if (!pf1_req) pf1_st <= C_IDLE;      // C_HOLD
			endcase

			case (pf2_st)
				C_IDLE: if (pf2_req) begin
					if (pf2_hit) begin
						pf2_data  <= pf2_b;
						pf2_group <= pf2_grp_w;
						pf2_ack   <= 1'b1;
						pf2_st    <= C_HOLD;
					end else pf2_st <= C_MISS;
				end
				C_MISS: if (pf2_fill) begin
					pf2_data  <= pf2_b;
					pf2_group <= pf2_grp_w;
					pf2_ack   <= 1'b1;
					pf2_st    <= C_HOLD;
				end
				default: if (!pf2_req) pf2_st <= C_IDLE;      // C_HOLD
			endcase

			case (mo_st)
				C_IDLE: if (mo_req) begin
					if (mo_hit) begin
						mo_data  <= mo_b;
						mo_group <= mo_grp_w;
						mo_ack   <= 1'b1;
						mo_st   <= C_HOLD;
					end else mo_st <= C_MISS;
				end
				C_MISS: if (mo_fill) begin
					mo_data  <= mo_b;
					mo_group <= mo_grp_w;
					mo_ack   <= 1'b1;
					mo_st   <= C_HOLD;
				end
				default: if (!mo_req) mo_st <= C_IDLE;      // C_HOLD
			endcase

			case (oki_st)
				C_IDLE: if (oki_req) begin
					if (oki_hit) begin
						oki_data <= oki_b;
						oki_ack  <= 1'b1;
						oki_st   <= C_HOLD;
					end else oki_st <= C_MISS;
				end
				C_MISS: if (oki_fill) begin
					oki_data <= oki_b;
					oki_ack  <= 1'b1;
					oki_st   <= C_HOLD;
				end
				default: if (!oki_req) oki_st <= C_IDLE;    // C_HOLD
			endcase
		end
	end

endmodule
