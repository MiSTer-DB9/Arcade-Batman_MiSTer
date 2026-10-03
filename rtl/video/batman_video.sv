`timescale 1ns/1ps
//============================================================================
//  Batman video block: the Atari VAD 137656-002 at 6F, the MOB 137593-001 at
//  10F, the two 137536-001 line buffers, the four priority GALs, the colour
//  RAM and the DACs, all behind the board's single /VRAM strobe.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//  Structure follows skullxbo_video.sv of the Skull & Crossbones MiSTer core
//  (GPL-3.0); see NOTICE.md.
//
//  The kit manual does not include the video schematic sheets (VAD, MOB, video
//  RAM, line buffers), so this block follows MAME's atarivad / atarimo, the GAL
//  fuse maps and sibling Atari cores, checked against MAME's frames.
//
//  /VRAM (F138 at 5/6K, A19:A17 = 111) covers a 128 KB window, decoded here:
//      +0x00000-0x00FFF   colour RAM, 2048 words   (A16 = 0)
//      +0x0FFC0-0x0FFFF   VAD registers            (A16 = 0)
//      +0x10000-0x1FFFF   video RAM, 32K words      (A16 = 1)
//  /VDTACK is returned when the target grants the cycle; registers answer at
//  once.  The 0x2Exxxx and 0x3Exxxx aliases reach the same hardware (GAL 9L
//  decides whether the 68000 waits).
//
//  MiSTer-only: the tile and sprite ROMs are in SDRAM behind three
//  batman_gfx_client ports; the 128 KB character ROM is in BRAM.  `gfx_late`
//  latches if any graphics fetch misses its deadline.
//
//  The colour reaches the DAC three pixels after the display count (layer
//  latch, mixer CRA register, colour latch), and sync/blank are delayed to
//  match, so the output needs no further compensation.
//============================================================================

module batman_video #(
	// ---- tuning; the defaults match MAME's frames pixel for pixel --------
	parameter int  PF1_XOFF   = 6,        // PF1 pixel offset
	parameter int  PF2_XOFF   = 2,        // PF2 pixel offset
	parameter int  HB_PHASE   = 0,        // active-video start, in 14M counts
	parameter int  PIPE       = 2,        // pixels from display count to mixer output
	parameter int  PFM_QUAL   = 0,        // 9D pins 15/16 wiring (batman_mixer)
	// Video-RAM words the motion-object walk may spend per line.  456 lets it
	// walk the whole line (456 pixel clocks); a smaller budget cut off sprites
	// in the staircase scene.
	parameter int  MO_BUDGET  = 456,
	parameter int  MO_XOFF    = 0,        // MO pixel offset
	parameter bit  MO_FIRST   = 1'b1,     // first object written wins (batman_lb)
	parameter bit  MO_ERASE   = 1'b1,     // clear the line buffer after display
	parameter int  STAIN_JOIN = 1,        // stain joins after the alpha mux
	parameter bit  COUPLE     = 1'b1,     // PF2 shares PF1's fine scroll
	// Motion-object engine enable; 0 is for debugging the other layers.
	parameter bit  MO_ENABLE  = 1'b1,
	parameter bit  VDTACK_LEVEL = 1'b1,   // see batman_vram
	parameter bit  IACK_STEALS  = 1'b0,   // see batman_vram
	parameter int  H_TOTAL    = 912,      // 14.318 MHz counts per line
	parameter int  H_VISIBLE  = 336       // visible pixels
)(
	input  logic        clk,
	input  logic        reset,          // FPGA power-up / download hold only;
	                                    // /SYSRES does not reach the VAD
	input  logic        ce_14m,

	// ---- the board's /VRAM port -------------------------------------------
	input  logic        vram_n,         // F138 5/6K Y7, level
	input  logic        rw,             // 1 = read, 0 = write
	input  logic [16:1] ma,             // MA16..MA1 inside the 128 KB window
	input  logic [15:0] din,            // the 68000's D15:0
	input  logic        wl_n,           // /WL, write the odd (low) byte
	input  logic        wu_n,           // /WU, write the even (high) byte
	input  logic        iack,           // the 68000 is in an interrupt acknowledge
	output logic [15:0] dout,
	output logic        vdtack_n,       // -> GAL 9L pin 9
	output logic        vint_n,         // the scanline interrupt, active low

	// ---- the LS273 1S output latch ----------------------------------------
	input  logic  [2:0] albk,           // alpha tile bank, latch bits 14:12

	// ---- character ROM download port (chars -> BRAM) ----------------------
	input  logic        char_wr,
	input  logic [16:0] char_addr,
	input  logic  [7:0] char_data,

	// ---- RAM preload port for simulation; tied off in the core -----------
	input  logic        snap_wr,
	input  logic        snap_cr,     // 1 = colour RAM, 0 = video RAM
	input  logic [14:0] snap_a,
	input  logic [15:0] snap_d,

	// ---- the three SDRAM byte clients (batman_gfx_mem) --------------------
	output logic        pf1_req,
	output logic [19:0] pf1_addr,
	input  logic        pf1_ack,
	input  logic [63:0] pf1_group,
	output logic        pf2_req,
	output logic [19:0] pf2_addr,
	input  logic        pf2_ack,
	input  logic [63:0] pf2_group,
	output logic        mo_req,
	output logic [21:0] mo_addr,
	input  logic        mo_ack,
	input  logic [127:0] mo_group,

	// ---- video out --------------------------------------------------------
	output logic        ce_pix,
	output logic  [7:0] vga_r, vga_g, vga_b,
	output logic        hsync, vsync, hblank, vblank,
	output logic [10:0] pix_index,
	// The board's /VBLANK, undelayed: it clocks the LS197 watchdog and appears
	// in the /STATUS word, so it must not carry the display pipeline delay.
	output logic        vblank_board,

	// ---- status, for debugging --------------------------------------------
	output logic        gfx_late,
	output logic [10:0] mo_words_line,
	output logic [10:0] cpu_words_line,
	output logic [10:0] dma_words_line,
	output logic [15:0] cpu_wait_worst,
	output logic [15:0] cram_steal,
	output logic        eof_late
);

	// =====================================================================
	//  The register file
	// =====================================================================
	wire        acc    = ~vram_n;
	wire        is_vr  = ma[16];
	wire        is_reg = ~ma[16] & (ma[15:6] == 10'h3FF);
	wire        is_cr  = ~ma[16] & ~is_reg;

	wire  [1:0] cpu_ds = {~wu_n, ~wl_n};
	wire        cpu_wr = acc & ~rw & (~wu_n | ~wl_n);

	// ---- a RAM access starts only once its data strobe is valid ---------
	// /VRAM and the address arrive with /AS, but on a write /WU and /WL (the
	// RAMs' write enables) come one 68000 clock later.  A RAM that granted a
	// slot in that gap would treat the write as a read and drop it, so a write
	// is not presented to the RAMs until a strobe is active.  The register
	// file answers at once and uses plain `acc`.
	wire        acc_arr = acc & (rw | cpu_wr);

	wire [15:0] reg_enable, reg_vsy, reg_vbl, reg_vint, reg_hsy, reg_hbl;
	wire [15:0] reg_slip, reg_apdma, reg_pmbase, reg_albase, reg_opt;
	wire [15:0] reg_mocon, reg_pcon, reg_grcon;
	wire        mob_wr;
	wire  [1:0] mob_sel;
	wire  [8:0] mo_xscroll, pf1_xscroll, pf2_xscroll, pf2_xscroll_raw;
	wire  [8:0] mo_yscroll, pf1_yscroll, pf2_yscroll;
	wire  [7:0] pf1_attr_latch, pf2_attr_latch;
	wire        oas_en, vad_enable, dma_enable, irq_arm, irq_ack;
	wire        ols_en, oslpink, osloram, o_dcdma, o_dvdma, oadroen;
	wire        ocrdwe, ovrdtack, ocrdtack, opium, opfhsiz_pf2at;
	wire        eof_req;
	wire  [5:0] eof_idx;
	wire [15:0] eof_data, reg_dout, ls_d;
	wire        eof_ack, ls_wr;

	wire [9:0] h, hd, hpos;
	wire [8:0] v, vpos, v_next;
	wire       hsync_n, vsync_n, hblank_i, vblank_i, hde, vde;
	wire       line_start, frame_start, vblank_start, eof_window;

	batman_vad_regs #(.COUPLE_FINE(COUPLE)) u_regs (
		.clk(clk), .reset(reset),
		.cpu_cs(acc & is_reg), .cpu_we(cpu_wr & is_reg), .cpu_a(ma[5:1]),
		.cpu_din(din), .cpu_dout(reg_dout),
		.vpos(v), .vblank(vblank_i), .vblank_start(vblank_start),
		.eof_req(eof_req), .eof_idx(eof_idx),
		.eof_data(eof_data), .eof_ack(eof_ack),
		.ls_wr(ls_wr), .ls_d(ls_d),
		.reg_enable(reg_enable), .reg_vsy(reg_vsy), .reg_vbl(reg_vbl),
		.reg_vint(reg_vint), .reg_hsy(reg_hsy), .reg_hbl(reg_hbl),
		.reg_slip(reg_slip), .reg_apdma(reg_apdma), .reg_pmbase(reg_pmbase),
		.reg_albase(reg_albase), .reg_opt(reg_opt),
		.reg_mocon(reg_mocon), .reg_pcon(reg_pcon), .reg_grcon(reg_grcon),
		.mob_wr(mob_wr), .mob_sel(mob_sel),
		.mo_xscroll(mo_xscroll), .pf1_xscroll(pf1_xscroll),
		.pf2_xscroll(pf2_xscroll), .pf2_xscroll_raw(pf2_xscroll_raw),
		.mo_yscroll(mo_yscroll), .pf1_yscroll(pf1_yscroll),
		.pf2_yscroll(pf2_yscroll),
		.pf1_attr_latch(pf1_attr_latch), .pf2_attr_latch(pf2_attr_latch),
		.oas_en(oas_en),
		.ols_en(ols_en), .oslpink(oslpink), .osloram(osloram),
		.o_dcdma(o_dcdma), .o_dvdma(o_dvdma), .oadroen(oadroen),
		.ocrdwe(ocrdwe), .ovrdtack(ovrdtack), .ocrdtack(ocrdtack),
		.opium(opium), .opfhsiz_pf2at(opfhsiz_pf2at),
		.vad_enable(vad_enable), .dma_enable(dma_enable),
		.irq_arm(irq_arm), .irq_ack(irq_ack)
	);

	// =====================================================================
	//  The raster, out of registers 01 / 02 / 04 / 05
	// =====================================================================
	batman_vad_sync #(.H_TOTAL(H_TOTAL), .H_VISIBLE(H_VISIBLE),
	                  .HB_MODE(0), .HB_PHASE(HB_PHASE)) u_sync (
		.clk(clk), .reset(reset), .ce_14m(ce_14m),
		.vad_enable(vad_enable),
		.reg_vsy(reg_vsy), .reg_vbl(reg_vbl), .reg_vint(reg_vint),
		.reg_hsy(reg_hsy), .reg_hbl(reg_hbl),
		.irq_arm(irq_arm), .irq_ack(irq_ack),
		.h(h), .v(v), .hd(hd),
		.hsync_n(hsync_n), .vsync_n(vsync_n),
		.hblank(hblank_i), .vblank(vblank_i),
		.hde(hde), .vde(vde), .hpos(hpos), .vpos(vpos),
		.v_next(v_next),
		.line_start(line_start), .frame_start(frame_start),
		.vblank_start(vblank_start), .eof_window(eof_window),
		.vint_n(vint_n)
	);

	// The layers' pixel clock: `hd` advances on `ce_14m`, a pixel is two
	// counts, and a pixel ends on the `ce_14m` where `hd` is odd.
	wire       pix_half = hd[0];
	wire       ce_7m    = ce_14m & hd[0];
	wire [8:0] px       = hd[9:1];
	wire       blank    = hblank_i | vblank_i;

	assign ce_pix = ce_7m;

	// ---- delay the colour blanking to the pixel it applies to ---------------
	// The pixel leaving batman_mixer belongs to raster column h - PIPE, so the
	// blank that batman_cram applies with it is delayed by PIPE pixels too.
	// (The exported sync below is delayed PIPE + 1 for the colour latch.)
	localparam int BD = (PIPE < 0) ? 0 : PIPE;
	logic [3:0] d_bl;
	always_ff @(posedge clk) begin
		if (reset)         d_bl <= 4'hF;
		else if (ce_7m)    d_bl <= {d_bl[2:0], blank};
	end
	wire blank_px = (BD == 0) ? blank : d_bl[(BD == 0) ? 0 : BD-1];

	// ---- base addresses from registers 08 and 09 -------------------------
	wire [14:0] base_pf1  = {reg_pmbase[15:13], 12'b0};
	wire [14:0] base_pf2  = {reg_pmbase[12:10], 12'b0};
	wire [14:0] base_attr = {reg_pmbase[9:7],   12'b0};
	wire [14:0] base_al   = {reg_albase[9:6],   11'b0};
	wire [14:0] base_mo   = {reg_pmbase[5:1],   10'b0};
	wire [14:0] base_slip = base_al + {3'b000, reg_albase[5:0], 6'b0};

	// =====================================================================
	//  The video RAM and its slot schedule
	// =====================================================================
	wire [14:0] a_pf1c, a_pf1a, a_pf2c, a_pf2a, a_al;
	wire [15:0] q_pf1c, q_pf1a, q_pf2c, q_pf2a, q_al;
	wire        mo_vram_rd, mo_vram_ack;
	wire [14:0] mo_vram_a;
	wire [15:0] mo_vram_q;
	wire        dma_rq, dma_we, dma_ack;
	wire [14:0] dma_a;
	wire [15:0] dma_d, dma_q;
	wire        as_req;
	wire [14:0] as_a;
	wire [15:0] as_d;
	wire  [1:0] as_ds;
	wire        vr_grant, cpu_wr_stb;
	wire [14:0] cpu_wr_a;
	wire [15:0] vr_dout;
	wire        layer_late;

	batman_vram #(
		.VDTACK_LEVEL(VDTACK_LEVEL), .IACK_STEALS(IACK_STEALS)
	) u_vram (
		.clk(clk), .reset(reset), .ce_14m(ce_14m), .hd(hd), .blank(blank),
		.pf1_code_a(a_pf1c), .pf1_attr_a(a_pf1a),
		.pf2_code_a(a_pf2c), .pf2_attr_a(a_pf2a), .al_a(a_al),
		.pf1_code_q(q_pf1c), .pf1_attr_q(q_pf1a),
		.pf2_code_q(q_pf2c), .pf2_attr_q(q_pf2a), .al_q(q_al),
		.mo_req(mo_vram_rd), .mo_a(mo_vram_a),
		.mo_ack(mo_vram_ack), .mo_q(mo_vram_q),
		.dma_req(dma_rq), .dma_we(dma_we), .dma_a(dma_a), .dma_d(dma_d),
		.dma_ack(dma_ack), .dma_q(dma_q),
		.cpu_cs(acc_arr & is_vr), .cpu_we(cpu_wr & is_vr), .cpu_ds(cpu_ds),
		.cpu_a(ma[15:1]), .cpu_din(din), .cpu_dout(vr_dout),
		.cpu_grant(vr_grant), .ovrdtack(ovrdtack), .iack(iack),
		.cpu_wr_stb(cpu_wr_stb), .cpu_wr_a(cpu_wr_a),
		.as_req(as_req), .as_a(as_a), .as_d(as_d), .as_ds(as_ds),
		.init_wr(snap_wr & ~snap_cr), .init_a(snap_a), .init_d(snap_d),
		.mo_words_line(mo_words_line), .cpu_words_line(cpu_words_line),
		.dma_words_line(dma_words_line), .cpu_wait_worst(cpu_wait_worst),
		.layer_late(layer_late)
	);

	// =====================================================================
	//  The VAD's own DMA channel
	// =====================================================================
	/* verilator lint_off UNUSEDSIGNAL */
	wire [10:0] eof_words;
	/* verilator lint_on UNUSEDSIGNAL */

	batman_vad_dma u_dma (
		.clk(clk), .reset(reset),
		.line_start(line_start), .vpos(v), .vblank(vblank_i),
		.dma_enable(dma_enable), .ols_en(ols_en), .oas_en(oas_en),
		.base_pf1(base_pf1), .base_pf2(base_pf2), .base_attr(base_attr),
		.base_alpha(base_al), .base_slip(base_slip),
		.eof_req(eof_req), .eof_idx(eof_idx),
		.eof_data(eof_data), .eof_ack(eof_ack),
		.ls_wr(ls_wr), .ls_d(ls_d),
		.pf1_attr_latch(pf1_attr_latch), .pf2_attr_latch(pf2_attr_latch),
		.cpu_wr_stb(cpu_wr_stb), .cpu_wr_a(cpu_wr_a),
		.as_req(as_req), .as_a(as_a), .as_d(as_d), .as_ds(as_ds),
		.dma_rq(dma_rq), .dma_we(dma_we), .dma_a(dma_a), .dma_d(dma_d),
		.dma_ack(dma_ack), .dma_q(dma_q),
		.eof_words(eof_words), .eof_late(eof_late)
	);

	// =====================================================================
	//  The two playfields
	// =====================================================================
	wire        pf1_fetch, pf1_valid, pf1_late;
	wire [19:0] pf1_raddr;
	wire [31:0] pf1_grp;
	wire        pf2_fetch, pf2_valid, pf2_late;
	wire [19:0] pf2_raddr;
	wire [31:0] pf2_grp;
	wire  [3:0] pen1, col1, pen2, col2;
	wire  [1:0] pri1, pri2;

	batman_pf #(.ATTR_HIGH_BYTE(1'b1), .ROM_INVERT(1'b1), .XOFF(PF1_XOFF),
	            .H_PIX(H_TOTAL/2)) u_pf1 (
		.clk(clk), .reset(reset), .ce_7m(ce_7m), .px(px), .line(v), .line_next(v_next),
		.xscroll(pf1_xscroll), .yscroll(pf1_yscroll),
		.base_code(base_pf1), .base_attr(base_attr),
		.code_a(a_pf1c), .attr_a(a_pf1a), .code_q(q_pf1c), .attr_q(q_pf1a),
		.rom_fetch(pf1_fetch), .rom_addr(pf1_raddr), .rom_group(pf1_grp),
		.rom_valid(pf1_valid), .rom_late(pf1_late),
		.pen(pen1), .colour(col1), .pri(pri1));

	// OPIUM (reg 0A bit 14) enables playfield 2; when clear PF2 shows pen 0.
	// Batman always sets it.
	wire [3:0] pen2_g = opium ? pen2 : 4'd0;

	batman_pf #(.ATTR_HIGH_BYTE(1'b0), .ROM_INVERT(1'b1), .XOFF(PF2_XOFF),
	            .H_PIX(H_TOTAL/2)) u_pf2 (
		.clk(clk), .reset(reset), .ce_7m(ce_7m), .px(px), .line(v), .line_next(v_next),
		.xscroll(pf2_xscroll), .yscroll(pf2_yscroll),
		.base_code(base_pf2), .base_attr(base_attr),
		.code_a(a_pf2c), .attr_a(a_pf2a), .code_q(q_pf2c), .attr_q(q_pf2a),
		.rom_fetch(pf2_fetch), .rom_addr(pf2_raddr), .rom_group(pf2_grp),
		.rom_valid(pf2_valid), .rom_late(pf2_late),
		.pen(pen2), .colour(col2), .pri(pri2));

	// =====================================================================
	//  The alphanumerics, and their 128 KB character ROM in BRAM
	// =====================================================================
	wire [15:0] al_rom_a, al_rom_q;
	wire  [1:0] apix;
	wire  [3:0] alc;
	wire        albg;

	batman_alpha #(.H_PIX(H_TOTAL/2)) u_al (
		.clk(clk), .reset(reset), .ce_7m(ce_7m), .px(px), .line(v), .line_next(v_next),
		.albk(albk), .base_alpha(base_al),
		.vram_a(a_al), .vram_q(q_al),
		.rom_a(al_rom_a), .rom_q(al_rom_q),
		.apix(apix), .alc(alc), .albg(albg));

	// One array per byte lane, so Quartus infers BRAM: the download writes
	// bytes and the layer reads 16-bit words.
	logic [7:0] ch_hi [0:65535];
	logic [7:0] ch_lo [0:65535];
	logic [15:0] ch_q;
	always_ff @(posedge clk) begin
		if (char_wr && !char_addr[0]) ch_hi[char_addr[16:1]] <= char_data;
		if (char_wr &&  char_addr[0]) ch_lo[char_addr[16:1]] <= char_data;
		ch_q <= {ch_hi[al_rom_a], ch_lo[al_rom_a]};
	end
	assign al_rom_q = ch_q;

`ifndef ALTERA_RESERVED_QIS
	initial begin
		for (int i = 0; i < 65536; i++) begin
			ch_hi[i] = 8'h00;
			ch_lo[i] = 8'h00;
		end
	end
`endif

	// =====================================================================
	//  The motion objects and the two line buffers
	// =====================================================================
	wire        mob_fetch, mob_valid;
	wire [19:0] mob_raddr;
	wire [31:0] mob_grp;
	wire        mob_lb_we, mo_busy, mo_budget_hit, mo_line_over;
	wire  [9:0] mob_lb_a;
	wire [10:0] mob_lb_d, mo_words;
	logic       wbank;

	always_ff @(posedge clk) begin
		if (reset)           wbank <= 1'b0;
		else if (line_start) wbank <= ~wbank;
	end

	wire [8:0] mo_line = v + 9'd1;     // render line N+1 during line N

	batman_mob #(.MO_XOFF(MO_XOFF), .MO_WORD_BUDGET(MO_BUDGET)) u_mob (
		.clk(clk), .reset(reset),
		.line_start(line_start & MO_ENABLE), .vline(mo_line),
		.xscroll(mo_xscroll), .yscroll(mo_yscroll),
		.base_mo(base_mo), .base_slip(base_slip),
		.vram_a(mo_vram_a), .vram_rd(mo_vram_rd),
		.vram_ack(mo_vram_ack), .vram_q(mo_vram_q),
		.rom_fetch(mob_fetch), .rom_addr(mob_raddr),
		.rom_group(mob_grp), .rom_valid(mob_valid),
		.lb_we(mob_lb_we), .lb_a(mob_lb_a), .lb_d(mob_lb_d),
		.busy(mo_busy), .words(mo_words), .budget_hit(mo_budget_hit),
		.line_over(mo_line_over));

	wire [10:0] lb_q;

	batman_lb #(.LB_ERASE(MO_ERASE), .FIRST_WINS(MO_FIRST)) u_lb (
		.clk(clk), .reset(reset),
		.wbank(wbank),
		.we(mob_lb_we), .wa(mob_lb_a), .wd(mob_lb_d),
		.rd_ce(ce_7m), .ra({1'b0, px}), .q(lb_q));

	// =====================================================================
	//  The three SDRAM stamp clients
	// =====================================================================
	// One aligned 8-byte group per (code, row pair), four lanes at stride 2,
	// as batman_rom_loader lays it out.  The PF clients see the arbiter's
	// 8-byte row buffer, the MOB its 16-byte one.
	wire pf1_cl_late, pf2_cl_late, mo_cl_late;
	/* verilator lint_off UNUSEDSIGNAL */
	wire [3:0] pf1_blen, pf2_blen, mo_blen;
	/* verilator lint_on UNUSEDSIGNAL */

	batman_gfx_client #(.AW(20), .GROUP(8), .BEATS(4), .STRIDE(2)) u_pf1_rom (
		.clk(clk), .reset(reset),
		.fetch(pf1_fetch), .fetch_addr(pf1_raddr),
		.data(pf1_grp), .data_valid(pf1_valid), .late(pf1_cl_late),
		.req(pf1_req), .addr(pf1_addr), .blen(pf1_blen), .ack(pf1_ack),
		.group(pf1_group));

	batman_gfx_client #(.AW(20), .GROUP(8), .BEATS(4), .STRIDE(2)) u_pf2_rom (
		.clk(clk), .reset(reset),
		.fetch(pf2_fetch), .fetch_addr(pf2_raddr),
		.data(pf2_grp), .data_valid(pf2_valid), .late(pf2_cl_late),
		.req(pf2_req), .addr(pf2_addr), .blen(pf2_blen), .ack(pf2_ack),
		.group(pf2_group));

	wire [21:0] mo_addr_w;
	batman_gfx_client #(.AW(22), .GROUP(16), .BEATS(4), .STRIDE(2)) u_mo_rom (
		.clk(clk), .reset(reset),
		.fetch(mob_fetch), .fetch_addr({2'b00, mob_raddr}),
		.data(mob_grp), .data_valid(mob_valid), .late(mo_cl_late),
		.req(mo_req), .addr(mo_addr_w), .blen(mo_blen), .ack(mo_ack),
		.group(mo_group));
	assign mo_addr = mo_addr_w;

	always_ff @(posedge clk) begin
		if (reset)      gfx_late <= 1'b0;
		else if (pf1_late | pf2_late | pf1_cl_late | pf2_cl_late | mo_cl_late
		         | layer_late)
		                gfx_late <= 1'b1;
	end

	// =====================================================================
	//  The mixer: GALs 1006 -> 1004 -> 1003, and the stain latch beside 1005
	// =====================================================================
	// An MPR2 object is hidden from 9B/9C/9D (as in MAME) but still seen by 11D.
	wire [2:0] mo_mpr        = lb_q[10:8];
	wire [3:0] mo_colour     = lb_q[7:4];
	wire [3:0] mix_pen_raw_n = ~lb_q[3:0];
	wire [3:0] mix_pen_n     = mo_mpr[2] ? 4'b1111 : mix_pen_raw_n;

	// ---- PF1-vs-PF2 selection (done upstream of the GALs on the board) ----
	wire       pfxs = (pen1 == 4'd0);
	wire [9:0] pfx  = pfxs ? {pri2, col2, pen2_g} : {pri1, col1, pen1};

	wire [10:0] cram_index;
	wire        cs0, cs1, pfm, mo1_n, stain, lb_strobe_n, lb_phase_cmp;

	batman_mixer #(.STAIN_JOIN(STAIN_JOIN), .PFM_QUALIFIER(PFM_QUAL)) u_mix (
		.clk(clk), .reset(reset), .ce(ce_7m),
		.pfx(pfx), .pfxs(pfxs), .pf1_pen(pen1), .pf2_pen(pen2_g),
		.mo_pen_n(mix_pen_n), .mo_pen_n_stain(mix_pen_raw_n),
		.mo_col(mo_colour), .mpr(mo_mpr),
		.apix(apix), .alc(alc), .albg(albg),
		.lb_run_en(1'b0), .lb_phase(wbank), .lb_wr_en(1'b0),
		.lb_o13_en_n(1'b1), .lb_blank(~(hde & vde)),
		.cram_index(cram_index), .cs0(cs0), .cs1(cs1), .pfm(pfm),
		.mo1_n(mo1_n), .stain(stain),
		.lb_strobe_n(lb_strobe_n), .lb_phase_cmp(lb_phase_cmp));

	// =====================================================================
	//  The colour RAM and the DAC ladders
	// =====================================================================
	wire [15:0] colour, cr_dout;
	wire        cr_grant;

	batman_cram u_cram (
		.clk(clk), .reset(reset), .ce(ce_7m), .pix_half(pix_half),
		.pix_index(cram_index), .blank(blank_px),
		.cpu_cs(acc_arr & is_cr), .cpu_we(cpu_wr & is_cr), .cpu_ds(cpu_ds),
		.cpu_a(ma[11:1]), .cpu_din(din), .cpu_dout(cr_dout),
		.cpu_grant(cr_grant),
		.o_dcdma(o_dcdma), .ocrdtack(ocrdtack),
		.init_wr(snap_wr & snap_cr), .init_a(snap_a[10:0]), .init_d(snap_d),
		.colour(colour), .pix_index_out(pix_index), .steal(cram_steal));

	/* verilator lint_off UNUSEDSIGNAL */
	wire [5:0] code_r, code_g, code_b;
	/* verilator lint_on UNUSEDSIGNAL */

	batman_dac u_dac (
		.colour(colour),
		.code_r(code_r), .code_g(code_g), .code_b(code_b),
		.red(vga_r), .green(vga_g), .blue(vga_b));

	// =====================================================================
	//  The CPU read mux and /VDTACK
	// =====================================================================
	assign dout = is_reg ? reg_dout : (is_vr ? vr_dout : cr_dout);

	// A register access needs no RAM slot, so it is granted at once; the two
	// RAMs grant their own cycles.
	wire grant = acc & (is_reg ? 1'b1 : (is_vr ? vr_grant : cr_grant));
	assign vdtack_n = ~grant;

	// =====================================================================
	//  The three-pixel sync delay
	// =====================================================================
	localparam int SD = (PIPE < 0) ? 0 : (PIPE + 1);
	logic [3:0] d_hs, d_vs, d_hb, d_vb;
	always_ff @(posedge clk) begin
		if (reset) begin
			d_hs <= 4'hF; d_vs <= 4'hF; d_hb <= 4'hF; d_vb <= 4'hF;
		end else if (ce_7m) begin
			d_hs <= {d_hs[2:0], ~hsync_n};
			d_vs <= {d_vs[2:0], ~vsync_n};
			d_hb <= {d_hb[2:0],  hblank_i};
			d_vb <= {d_vb[2:0],  vblank_i};
		end
	end
	assign hsync  = d_hs[SD-1];
	assign vsync  = d_vs[SD-1];
	assign hblank = d_hb[SD-1];
	assign vblank = d_vb[SD-1];
	assign vblank_board = vblank_i;

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused_vid = &{1'b0,
	                     h, hpos, vpos, hde, vde, frame_start, eof_window,
	                     reg_slip, reg_apdma, reg_enable, reg_opt,
	                     reg_pmbase[6], reg_pmbase[0], reg_albase[15:10],
	                     reg_mocon, reg_pcon,
	                     reg_grcon, mob_wr, mob_sel, pf2_xscroll_raw,
	                     oslpink, osloram, o_dvdma, oadroen, ocrdwe,
	                     opfhsiz_pf2at, cs0, cs1, pfm, mo1_n, stain,
	                     lb_strobe_n, lb_phase_cmp, mo_busy, mo_budget_hit,
	                     mo_line_over, mo_words, eof_words,
	                     d_hs[3], d_vs[3], d_hb[3], d_vb[3],
	                     1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
