`timescale 1ns/1ps
//============================================================================
//  Batman (Atari Games, 1990/91) - game logic top, below the MiSTer emu glue.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.  Structure follows
//  skullxbo_core.sv of the Skull & Crossbones MiSTer core (GPL-3.0); see
//  NOTICE.md.
//
//  Blocks:
//    batman_main   the 68000 game PCB A048987-01: CPU, address decode, wait
//                  states, work RAM, EEPROM, watchdog, inputs and latches,
//                  program ROM in SDRAM, interrupts.  It also owns the ROM
//                  loader and the SDRAM controller and arbiter.
//    batman_video  the VAD + MOB 137593-001 video system: playfields,
//                  alphanumerics, motion objects, colour RAM and DACs.  All
//                  raster timing comes from the VAD's sync registers.
//    batman_sound  the JSA III audio PCB A048974-01, connected through the
//                  36-pin audio header that batman_main provides.
//
//  One clock domain: clk_sys = 57.272727 MHz with integer clock enables.
//  Instance names u_main|u_cpu|u_fx68k, u_sound|u_cpu|u_t65 and
//  u_sound|u_ym|u_jt51 are referenced by Batman.sdc; a timing exception whose
//  path does not match is silently skipped, so keep them.
//
//  Resets:
//    init_reset  ~pll_locked only.  The only reset the SDRAM controller and
//                ROM loader see: resetting them during a download would restart
//                SDRAM init and lose data.  batman_main routes it to those alone.
//    game_reset  OSD reset or ROMs not yet loaded; formed inside batman_main,
//                where it re-runs the board power-on reset (/SYSRES).
//    vid_reset   init_reset or ROMs not loaded, but not the OSD reset: the
//                video block keeps running through a board reset.
//    snd_por     power-on reset of the JSA III board.  The 6502's /RESET from
//                the game board's LS273 1S latch (sndres_n) is a separate net.
//============================================================================

module batman_core #(
	// 68000 clock, chosen on the board by jumpers SP4 (CLK) / SP3 (7MHZ); which
	// is fitted is not known.  1 = 14.318181 MHz (as MAME), 0 = 7.159 MHz.
	parameter bit CPU_14M = 1'b1,

	// R80 * C115 = 10 ms of power-on reset (from the schematic).  Simulation
	// may shorten it.
	parameter int POR_US = 10000,

	// The 28C16 EEPROM's self-timed byte write (10 ms), in clk_sys cycles.
	parameter int EEPROM_WRITE_CYCLES = 57272727 / 100
)(
	input  logic        clk_sys,        // 57.272727 MHz
	input  logic        reset,          // active-high system/OSD reset
	input  logic        init_reset,     // ~pll_locked only (SDRAM + loaders)

	// ---- HPS ioctl: index 0 = the ROM stream, index 2 = the EEPROM ----
	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,
	output logic        ioctl_wait,
	input  logic        ioctl_upload,
	output logic        ioctl_upload_req,
	output logic  [7:0] ioctl_upload_index,
	output logic  [7:0] ioctl_din,

	// ---- controls, active high = "pressed" (batman_inputs forms the board's
	//      active-low senses).  P1 is at 0x260000; the P2 set at 0x260002 is
	//      wired on the board but never read by the game.
	//      COIN1/COIN2/TILT are read only by the JSA III 6502.  SELF TEST is
	//      one net seen by both boards (0x260010 D6 on the game PCB).
	//      /SERVICE and /SERVICE2 are 0x260012 D4/D5 and also on the audio
	//      header.
	input  logic        self_test,      // OSD "Service", high = on
	input  logic        service,        // JAMMA-R  /SERVICE  (= JSA SERVICE1)
	input  logic        tilt,           // JAMMA-S, JSA III only
	input  logic  [3:0] p1_joy,         // {up, down, left, right}
	input  logic  [3:0] p2_joy,
	input  logic        p1_b1, p1_b2, p1_b3, p1_start,
	input  logic        p2_b1, p2_b2, p2_b3, p2_start,
	input  logic        coin1, coin2,

	// ---- the two JAMMA coin-counter drivers, from the JSA III 6502's
	//      /WRIO bits 0x10 / 0x20 ----
	output logic        cctr1,
	output logic        cctr2,

	// ---- video out (single clk_sys domain, qualified by ce_pix) ----
	output logic        ce_pix,
	output logic  [7:0] vga_r, vga_g, vga_b,
	output logic        hsync, vsync, hblank, vblank,
	// the palette index (2048-entry colour RAM) of the pixel on vga_*, for
	// simulation.  Not used by the MiSTer glue.
	output logic [10:0] pix_index,

	// ---- audio (the JSA III is mono: both carry one signal) ----
	output logic signed [15:0] aud_l, aud_r,

	// ---- observability ----
	output logic        rom_loaded,     // the index-0 download has finished

	// ---- SDRAM chip ----
	inout  wire  [15:0] SDRAM_DQ,
	output logic [12:0] SDRAM_A,
	output logic  [1:0] SDRAM_BA,
	output logic        SDRAM_DQML,
	output logic        SDRAM_DQMH,
	output logic        SDRAM_CKE,
	output logic        SDRAM_nCS,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_nWE
);

	// =====================================================================
	//  resets (see the header)
	// =====================================================================
	wire vid_reset = init_reset | ~rom_loaded;
	wire snd_por   = init_reset | reset | ~rom_loaded;

	// =====================================================================
	//  the clock-enable tree
	// =====================================================================
	wire ce_14m, ce_7m, ce_3m58, ce_1m79, ce_1m19;

	batman_clocks u_clocks (
		.clk_sys (clk_sys),
		.ce_14m  (ce_14m),
		.ce_7m   (ce_7m),
		.ce_3m58 (ce_3m58),
		.ce_1m79 (ce_1m79),
		.ce_1m19 (ce_1m19)
	);

	// =====================================================================
	//  the video system: the VAD and the MOB
	// =====================================================================
	// The CPU reaches the whole video system through one strobe, /VRAM
	// (F138 5/6K Y7), plus the /VDTACK handshake and the /VINT interrupt.
	wire        vad_vram_n, vad_rw, vad_wl_n, vad_wu_n, vad_vdtack_n, vad_vint_n;
	wire        vad_iack;
	wire [16:1] vad_ma;
	wire [15:0] vad_din, vad_dout;
	wire        vblank_board;

	/* verilator lint_off UNUSEDSIGNAL */
	wire        gfx_late, eof_late;
	wire [10:0] dbg_mo_words, dbg_cpu_words, dbg_dma_words;
	wire [15:0] dbg_cpu_wait, dbg_cram_steal;
	/* verilator lint_on UNUSEDSIGNAL */

	batman_video u_video (
		.clk        (clk_sys),
		.reset      (vid_reset),
		.ce_14m     (ce_14m),

		.vram_n     (vad_vram_n),
		.rw         (vad_rw),
		.ma         (vad_ma),
		.din        (vad_din),
		.wl_n       (vad_wl_n),
		.wu_n       (vad_wu_n),
		.iack       (vad_iack),
		.dout       (vad_dout),
		.vdtack_n   (vad_vdtack_n),
		.vint_n     (vad_vint_n),

		.albk       (albk),

		.char_wr    (char_wr),
		.char_addr  (char_addr),
		.char_data  (rom_data),

		// the snapshot port is for simulation only; tied off here and pruned
		.snap_wr    (1'b0),
		.snap_cr    (1'b0),
		.snap_a     (15'd0),
		.snap_d     (16'd0),

		.pf1_req    (pf1_req), .pf1_addr (pf1_addr),
		.pf1_ack    (pf1_ack), .pf1_group (pf1_group),
		.pf2_req    (pf2_req), .pf2_addr (pf2_addr),
		.pf2_ack    (pf2_ack), .pf2_group (pf2_group),
		.mo_req     (mo_req),  .mo_addr  (mo_addr),
		.mo_ack     (mo_ack),  .mo_group (mo_group),

		.ce_pix     (ce_pix),
		.vga_r      (vga_r), .vga_g (vga_g), .vga_b (vga_b),
		.hsync      (hsync), .vsync (vsync),
		.hblank     (hblank), .vblank (vblank),
		.pix_index  (pix_index),
		.vblank_board (vblank_board),

		.gfx_late       (gfx_late),
		.mo_words_line  (dbg_mo_words),
		.cpu_words_line (dbg_cpu_words),
		.dma_words_line (dbg_dma_words),
		.cpu_wait_worst (dbg_cpu_wait),
		.cram_steal     (dbg_cram_steal),
		.eof_late       (eof_late)
	);

	// =====================================================================
	//  the 36-pin audio header
	// =====================================================================
	// Driven by batman_main, used by batman_sound: /SNDRES from the LS273 1S,
	// the two /SCOM strobes with the 68000's odd byte, and /AUDIRQ, /AUDFULL
	// and the mailbox byte coming back.
	wire       sndres_n, scomrd_n, scomwr_n, scomrd_stb, scomwr_stb;
	wire [7:0] scom_wdata;
	wire       audirq_n, audfull_n;
	wire [7:0] scom_rdata;

	// =====================================================================
	//  the LS273 1S output latch bits that leave the main board
	// =====================================================================
	// CC_R / CC_L reach the coin counters only through jumpers SP1/SP2, drawn
	// open; the counters are driven by the JSA III instead (cctr1/cctr2).
	// ALBK0-2 select the alphanumerics bank; GRBK0 and VCR are unused.
	wire       cc_r, cc_l, grbk0, vcr;
	wire [2:0] albk;

	// =====================================================================
	//  the SDRAM read clients
	// =====================================================================
	// batman_main owns the SDRAM controller and serves the video fetchers
	// (two playfields, motion objects) and the MSM6295 sample stream (512 KB,
	// 19 address bits).  The byte-wide *_data returns are unused by video.
	wire         pf1_req, pf2_req, mo_req;
	wire  [19:0] pf1_addr, pf2_addr;
	wire  [21:0] mo_addr;
	wire         pf1_ack, pf2_ack, mo_ack;
	wire  [63:0] pf1_group, pf2_group;
	wire [127:0] mo_group;
	/* verilator lint_off UNUSEDSIGNAL */
	wire   [7:0] pf1_data, pf2_data, mo_data;
	/* verilator lint_on UNUSEDSIGNAL */

	wire        oki_req, oki_ack;
	wire [18:0] oki_addr;
	wire  [7:0] oki_data;

	// BRAM side ports of the ROM loader: the loader copies the 6502 program
	// into the JSA III's BRAM, and the alphanumerics ROM into the video
	// system's BRAM, as the download passes.
	wire        char_wr, snd_wr;
	wire [16:0] char_addr;
	wire [15:0] snd_addr;
	wire  [7:0] rom_data;

	// =====================================================================
	//  debug nets, read by simulation; Quartus prunes them
	// =====================================================================
	wire [23:1] dbg_cpu_a;
	wire        dbg_cpu_as, dbg_cpu_rw, dbg_cpu_uds_n, dbg_cpu_lds_n, dbg_cpu_dtack;
	wire [15:0] dbg_cpu_rdata, dbg_cpu_wdata;
	wire  [2:0] dbg_cpu_fc;
	wire        dbg_sysres_n;
	wire  [7:0] dbg_latch_q;

	// =====================================================================
	//  the 68000 game PCB A048987-01
	// =====================================================================
	batman_main #(
		.CPU_14M             (CPU_14M),
		.POR_US              (POR_US),
		.EEPROM_WRITE_CYCLES (EEPROM_WRITE_CYCLES)
	) u_main (
		.clk        (clk_sys),
		.ce_14m     (ce_14m),
		.ce_7m      (ce_7m),
		.init_reset (init_reset),
		.ext_reset  (reset),

		// the video side
		.vad_vram_n   (vad_vram_n),
		.vad_rw       (vad_rw),
		.vad_ma       (vad_ma),
		.vad_din      (vad_din),
		.vad_wl_n     (vad_wl_n),
		.vad_wu_n     (vad_wu_n),
		.vad_dout     (vad_dout),
		.vad_vdtack_n (vad_vdtack_n),
		.vad_vint_n   (vad_vint_n),
		.vad_iack     (vad_iack),
		// the board's /VBLANK: it clocks the LS197 watchdog and is a /STATUS
		// bit, so it must not carry the display pipeline's three-pixel delay.
		.vblank       (vblank_board),

		// the audio header
		.sndres_n   (sndres_n),
		.audfull_n  (audfull_n),
		.audirq_n   (audirq_n),
		.scomrd_n   (scomrd_n),
		.scomwr_n   (scomwr_n),
		.scomrd_stb (scomrd_stb),
		.scomwr_stb (scomwr_stb),
		.scom_wdata (scom_wdata),
		.scom_rdata (scom_rdata),

		// the rest of the LS273 1S
		.cc_r (cc_r), .cc_l (cc_l), .grbk0 (grbk0), .albk (albk), .vcr (vcr),

		// the cabinet, active high.  D9 = FIRE, D10 = ACTA ("JUMP"), D8 = START:
		// the pad's Fire / Jump / Start.  D11 = ACTB is wired but never read by
		// the game, so it is held released.  /SERVICE2 (JAMMA-CC) has no OSD
		// control and is released.
		.self_test (self_test),
		.service   (service),
		.service2  (1'b0),
		.p1_joy    (p1_joy),
		.p2_joy    (p2_joy),
		.p1_fire (p1_b1), .p1_acta (p1_b2), .p1_actb (p1_b3), .p1_start (p1_start),
		.p2_fire (p2_b1), .p2_acta (p2_b2), .p2_actb (p2_b3), .p2_start (p2_start),

		// the ioctl channels: index 0 is the ROM stream, index 2 the EEPROM
		.ioctl_download     (ioctl_download),
		.ioctl_wr           (ioctl_wr),
		.ioctl_addr         (ioctl_addr),
		.ioctl_dout         (ioctl_dout),
		.ioctl_index        (ioctl_index),
		.ioctl_wait         (ioctl_wait),
		.ioctl_upload       (ioctl_upload),
		.ioctl_upload_req   (ioctl_upload_req),
		.ioctl_upload_index (ioctl_upload_index),
		.ioctl_din          (ioctl_din),
		.rom_loaded         (rom_loaded),

		// the SDRAM clients
		.pf1_req (pf1_req), .pf1_addr (pf1_addr), .pf1_ack (pf1_ack),
		.pf1_data (pf1_data), .pf1_group (pf1_group),
		.pf2_req (pf2_req), .pf2_addr (pf2_addr), .pf2_ack (pf2_ack),
		.pf2_data (pf2_data), .pf2_group (pf2_group),
		.mo_req (mo_req), .mo_addr (mo_addr), .mo_ack (mo_ack),
		.mo_data (mo_data), .mo_group (mo_group),
		.oki_req (oki_req), .oki_addr (oki_addr), .oki_ack (oki_ack),
		.oki_data (oki_data),

		.char_wr (char_wr), .char_addr (char_addr),
		.snd_wr (snd_wr), .snd_addr (snd_addr), .rom_data (rom_data),

		.SDRAM_DQ (SDRAM_DQ), .SDRAM_A (SDRAM_A), .SDRAM_BA (SDRAM_BA),
		.SDRAM_DQML (SDRAM_DQML), .SDRAM_DQMH (SDRAM_DQMH),
		.SDRAM_CKE (SDRAM_CKE), .SDRAM_nCS (SDRAM_nCS),
		.SDRAM_nRAS (SDRAM_nRAS), .SDRAM_nCAS (SDRAM_nCAS),
		.SDRAM_nWE (SDRAM_nWE),

		.cpu_a (dbg_cpu_a), .cpu_as (dbg_cpu_as), .cpu_rw (dbg_cpu_rw),
		.cpu_uds_n (dbg_cpu_uds_n), .cpu_lds_n (dbg_cpu_lds_n),
		.cpu_rdata (dbg_cpu_rdata), .cpu_wdata (dbg_cpu_wdata),
		.cpu_fc (dbg_cpu_fc), .cpu_dtack (dbg_cpu_dtack),
		.sysres_n (dbg_sysres_n), .latch_q (dbg_latch_q)
	);

	// =====================================================================
	//  the JSA III audio board A048974-01
	// =====================================================================
	// The instance must be named u_sound: Batman.sdc refers to
	// *u_sound|u_cpu|u_t65|* and *u_sound|u_ym|u_jt51|*.
	// COIN1, COIN2 and TILT are read only by the 6502 on /RDIO; SELF TEST is
	// seen by both boards.  The coin counters come from the JSA's /WRIO bits.
	wire        cctr_wor;
	wire [15:0] sdbg_cpu_addr;
	wire  [7:0] sdbg_cpu_dout, sdbg_cpu_din, sdbg_sel;
	wire        sdbg_cpu_rnw, sdbg_cpu_sync, sdbg_o2, sdbg_sel_vol;
	wire        sdbg_irq_n, sdbg_nmi_n, sdbg_ms4irq, sdbg_clipped;

	batman_sound u_sound (
		.clk(clk_sys), .ce_3m58(ce_3m58), .ce_1m79(ce_1m79), .ce_1m19(ce_1m19),
		.por(snd_por),
		// the 36-pin audio header, from batman_main
		.scom_wr(scomwr_stb),  .scom_wr_data(scom_wdata),
		.scom_rd(scomrd_stb),  .scom_rd_data(scom_rdata),
		.audirq_n(audirq_n),   .audfull_n(audfull_n),
		.sndres(~sndres_n),               // the block wants "1 = held"
		// board inputs, active high = closed / pressed
		.self_test(self_test), .service(service), .tilt(tilt),
		.coin_l(coin1),        .coin_r(coin2),
		.cctr1(cctr1), .cctr2(cctr2), .cctr_wired_or(cctr_wor),
		// the 64 KB 6502 program ROM, from batman_main's loader port
		.rom_wr(snd_wr), .rom_addr(snd_addr), .rom_data(rom_data),
		// the 512 KB sample-ROM byte client -> batman_main's arbiter
		.oki_req(oki_req), .oki_addr(oki_addr),
		.oki_ack(oki_ack), .oki_data(oki_data),
		.audio_l(aud_l), .audio_r(aud_r),
		// diagnostics: unused, but connected to named nets to avoid lint
		// warnings and to be visible in SignalTap.
		.dbg_cpu_addr(sdbg_cpu_addr), .dbg_cpu_dout(sdbg_cpu_dout),
		.dbg_cpu_din(sdbg_cpu_din),   .dbg_cpu_rnw(sdbg_cpu_rnw),
		.dbg_cpu_sync(sdbg_cpu_sync), .dbg_o2(sdbg_o2),
		.dbg_sel(sdbg_sel),           .dbg_sel_vol(sdbg_sel_vol),
		.dbg_irq_n(sdbg_irq_n),       .dbg_nmi_n(sdbg_nmi_n),
		.dbg_ms4irq(sdbg_ms4irq),     .dbg_clipped(sdbg_clipped)
	);

	// =====================================================================
	//  outputs this top does not use
	// =====================================================================
	// Collected in one place so Verilator -Wall and Quartus stay quiet.
	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused_core = &{1'b0,
	                      scomrd_n, scomwr_n,
	                      cc_r, cc_l, grbk0, vcr,
	                      pf1_data, pf2_data, mo_data,
	                      gfx_late, eof_late, dbg_mo_words, dbg_cpu_words,
	                      dbg_dma_words, dbg_cpu_wait, dbg_cram_steal,
	                      dbg_cpu_a, dbg_cpu_as, dbg_cpu_rw, dbg_cpu_uds_n,
	                      dbg_cpu_lds_n, dbg_cpu_rdata, dbg_cpu_wdata,
	                      dbg_cpu_fc, dbg_cpu_dtack, dbg_sysres_n, dbg_latch_q,
	                      cctr_wor,
	                      sdbg_cpu_addr, sdbg_cpu_dout, sdbg_cpu_din, sdbg_sel,
	                      sdbg_cpu_rnw, sdbg_cpu_sync, sdbg_o2, sdbg_sel_vol,
	                      sdbg_irq_n, sdbg_nmi_n, sdbg_ms4irq, sdbg_clipped,
	                      1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
