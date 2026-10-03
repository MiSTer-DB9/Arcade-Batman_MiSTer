`timescale 1ns/1ps
//============================================================================
//  Batman game PCB A048987-01, 68000 side: the CPU at 6L/M, the address
//  decode, the wait counter, 64 KB work RAM, the 28C16 EEPROM, the watchdog,
//  the input muxes, the LS273 output latch and the interrupt encoder, plus
//  the MiSTer ROM loader and SDRAM that hold the program and graphics ROMs.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.  Structure follows the Skull &
//  Crossbones MiSTer core (GPL-3.0); see NOTICE.md.
//
//  The video chips (VAD, MOB) are reached through the /VRAM strobe and the
//  vad_* ports; the JSA III sound board through the AUDIO header ports.  The
//  data bus has no buffers or pull-ups, so any lane nothing drives reads as
//  UNDRIVEN_DATA (0xFFFF, as MAME).  One difference from the board: the
//  program ROM is read from SDRAM through a cache, and a cache miss delays
//  /DTACK; the real ROM always answers in five CPU clocks.
//============================================================================

module batman_main #(
	parameter int CLK_HZ = 57272727,

	// 1 = 68000 at 14.318 MHz (as MAME), 0 = 7.159 MHz.  The board selects it
	// with jumpers SP3/SP4.  Passed to both batman_cpu and batman_dtack.
	parameter bit CPU_14M = 1'b1,

	// What a data-bus lane that nothing drives reads as.
	parameter logic [15:0] UNDRIVEN_DATA = 16'hFFFF,

	// Power-on RC delay (R80 x C115, ~10 ms), before the 8-frame watchdog count.
	parameter int POR_US = 10000,
	// 1 = the WDOG strap is fitted, which defeats the watchdog.
	parameter bit WDOG_STRAP = 1'b0,

	// The 28C16's self-timed byte write, in clk_sys cycles.
	parameter int EEPROM_WRITE_CYCLES = CLK_HZ / 100,

	// Program-ROM cache size in lines of 4 words: 2048 -> 16 KB, 20 M10K.
	parameter int PROG_CACHE_LINES = 2048,

	// SDRAM word address of the program ROM.
	parameter int AW = 24,
	parameter logic [AW-1:0] PROG_BASE = 24'h000000
)(
	input  logic        clk,            // clk_sys 57.272727 MHz
	input  logic        ce_14m,         // clk_sys/4
	input  logic        ce_7m,          // clk_sys/8
	input  logic        init_reset,     // ~pll_locked only
	input  logic        ext_reset,      // OSD reset; re-runs the board power-on reset

	// ================= the video side ====================================
	// One strobe from the F138 plus the handshake; the VAD does its own fine
	// address decode.
	output logic        vad_vram_n,     // /VRAM, LEVEL
	output logic        vad_rw,         // 1 = read
	output logic [16:1] vad_ma,         // MA16..MA1 inside the 128 KB window
	output logic [15:0] vad_din,        // the 68000's D15:0
	output logic        vad_wl_n,       // /WL, write the odd (low) byte
	output logic        vad_wu_n,       // /WU, write the even (high) byte
	input  logic [15:0] vad_dout,
	input  logic        vad_vdtack_n,   // -> GAL 9L pin 9
	input  logic        vad_vint_n,     // the scanline interrupt, ACTIVE LOW
	// In an interrupt acknowledge the address is 0x3FFFFx and /VRAM really
	// strobes; this flag tells the VAD the access is not a real one.
	output logic        vad_iack,
	input  logic        vblank,         // the VAD's /VBLANK, ACTIVE HIGH here

	// ================= the 36-pin AUDIO header ===========================
	output logic        sndres_n,       // pin 1,  latch 3Q, a level
	input  logic        audfull_n,      // pin 2,  IN
	input  logic        audirq_n,       // pin 3,  IN, to /STATUS D4 and /IPL1
	output logic        scomrd_n,       // pin 4,  /SCOM-RD, LEVEL
	output logic        scomwr_n,       // pin 5,  /SCOM-WR, LEVEL
	output logic        scomrd_stb,     // 1-clk pulse at the END of /SCOM-RD
	output logic        scomwr_stb,     // 1-clk pulse at the END of /SCOM-WR
	output logic  [7:0] scom_wdata,     // pins 6-13, the 68000's ODD byte
	input  logic  [7:0] scom_rdata,     // pins 6-13, the JSA III's answer

	// ================= the rest of the LS273 1S ==========================
	output logic        cc_r,           // 1Q  D0   right coin counter
	output logic        cc_l,           // 2Q  D1   left coin counter
	output logic        grbk0,          // 4Q  D11  graphics bank bit 0
	output logic  [2:0] albk,           // 7Q..5Q   alpha tile bank
	output logic        vcr,            // 8Q  D8   VCR/DEV_ONLY jumper

	// ================= the cabinet =======================================
	input  logic        self_test,      // ACTIVE HIGH = the switch is ON
	input  logic        service,        // JAMMA-R  /SERVICE
	input  logic        service2,       // JAMMA-CC /SERVICE2
	input  logic  [3:0] p1_joy,         // {up, down, left, right}
	input  logic  [3:0] p2_joy,
	input  logic        p1_fire, p1_acta, p1_actb, p1_start,
	input  logic        p2_fire, p2_acta, p2_actb, p2_start,

	// ================= the MiSTer ioctl channels =========================
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
	output logic        rom_loaded,

	// ================= SDRAM byte clients (video and sound) ==============
	// Two playfield clients, because the layers share only the fine scroll
	// and so fetch different tile columns.
	input  logic        pf1_req,
	input  logic [19:0] pf1_addr,
	output logic        pf1_ack,
	output logic  [7:0] pf1_data,
	output logic [63:0] pf1_group,
	input  logic        pf2_req,
	input  logic [19:0] pf2_addr,
	output logic        pf2_ack,
	output logic  [7:0] pf2_data,
	output logic [63:0] pf2_group,
	input  logic        mo_req,
	input  logic [21:0] mo_addr,
	output logic        mo_ack,
	output logic  [7:0] mo_data,
	output logic [127:0] mo_group,
	input  logic        oki_req,
	input  logic [18:0] oki_addr,   // 19 bits: the ADPCM ROM is 512 KB
	output logic        oki_ack,
	output logic  [7:0] oki_data,

	// ================= the two block-RAM download ports ==================
	output logic        char_wr,
	output logic [16:0] char_addr,   // the 128 KB alpha ROM lives in block RAM
	output logic        snd_wr,
	output logic [15:0] snd_addr,
	output logic  [7:0] rom_data,

	// ================= the SDRAM chip ====================================
	inout  wire  [15:0] SDRAM_DQ,
	output logic [12:0] SDRAM_A,
	output logic  [1:0] SDRAM_BA,
	output logic        SDRAM_DQML,
	output logic        SDRAM_DQMH,
	output logic        SDRAM_CKE,
	output logic        SDRAM_nCS,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_nWE,

	// ================= observability =====================================
	output logic [23:1] cpu_a,
	output logic        cpu_as,        // ACTIVE HIGH copy of /AS (= BAS)
	output logic        cpu_rw,        // 1 = read
	output logic        cpu_uds_n,
	output logic        cpu_lds_n,
	output logic [15:0] cpu_rdata,
	output logic [15:0] cpu_wdata,
	output logic  [2:0] cpu_fc,
	output logic        cpu_dtack,     // ACTIVE HIGH
	output logic        sysres_n,      // the /SYSRES net
	output logic  [7:0] latch_q        // the whole LS273 1S
);

	// =====================================================================
	//  the resets
	// =====================================================================
	// MiSTer reset (OSD or ROM download) re-runs the power-on node, so /SYSRES
	// is held for a further eight /VBLANK edges, as at power-up.
	wire game_reset = ext_reset | ~rom_loaded;
	wire mem_reset  = init_reset | ~rom_loaded;

	// =====================================================================
	//  the 68000 at 6L/M
	// =====================================================================
	wire [23:1] a;
	wire        as, rw, uds_n, lds_n, dtack, vpa_n, ce_cpu;
	wire  [2:0] fc, ipl;
	wire [15:0] cpu_dout, cpu_din;

	/* verilator lint_off UNUSEDSIGNAL */
	wire        reset_inst;      // no load on the board
	/* verilator lint_on UNUSEDSIGNAL */

	batman_cpu #(.CPU_14M(CPU_14M)) u_cpu (
		.clk        (clk),
		.ce_14m     (ce_14m),
		.ce_7m      (ce_7m),
		.reset      (~sysres_n | game_reset),
		.ipl        (ipl),
		.a          (a),
		.wdata      (cpu_dout),
		.rdata      (cpu_din),
		.as         (as),
		.uds_n      (uds_n),
		.lds_n      (lds_n),
		.rw         (rw),
		.dtack      (dtack),
		.vpa_n      (vpa_n),
		.fc         (fc),
		.reset_inst (reset_inst),
		.ce_cpu     (ce_cpu)
	);

	// ---- glue gates ------------------------------------------------------
	//   BAS = NOT /AS (12M LS04), /WL = R/W OR /LDS, /WU = R/W OR /UDS (7K F32)
	wire bas  = as;
	wire wl_n = rw | lds_n;
	wire wu_n = rw | uds_n;

	// =====================================================================
	//  the decode: GAL 9L + F138 5/6K + LS138 1P/R
	// =====================================================================
	wire rom0_n, rom1_n, rom2_n, rom3_n;
	wire wait_n, wait2_n, vrwait_n, ioen_n;
	wire com_n, eeprom_n, cio_n, wdog_n, vram_n;
	wire f138_y2_n, f138_y4_n, f138_y6_n;
	wire plsws_n, status_n, latch_n, unlock_n;
	wire ls138_y2_n, ls138_y7_n;

	batman_decode u_dec (
		.as         (bas),
		.a          (a[21:1]),
		.vdtack_n   (vad_vdtack_n),

		.rom0_n     (rom0_n),
		.rom1_n     (rom1_n),
		.rom2_n     (rom2_n),
		.rom3_n     (rom3_n),
		.wait_n     (wait_n),
		.wait2_n    (wait2_n),
		.vrwait_n   (vrwait_n),
		.ioen_n     (ioen_n),

		.com_n      (com_n),
		.eeprom_n   (eeprom_n),
		.f138_y2_n  (f138_y2_n),
		.cio_n      (cio_n),
		.f138_y4_n  (f138_y4_n),
		.wdog_n     (wdog_n),
		.f138_y6_n  (f138_y6_n),
		.vram_n     (vram_n),

		.plsws_n    (plsws_n),
		.status_n   (status_n),
		.ls138_y2_n (ls138_y2_n),
		.scomrd_n   (scomrd_n),
		.scomwr_n   (scomwr_n),
		.latch_n    (latch_n),
		.unlock_n   (unlock_n),
		.ls138_y7_n (ls138_y7_n)
	);

	// =====================================================================
	//  /DTACK: the F163 8K wait counter
	// =====================================================================
	wire dtack_163;
	/* verilator lint_off UNUSEDSIGNAL */
	wire [3:0] dtack_count;
	wire       dtack_ce_cpu;
	/* verilator lint_on UNUSEDSIGNAL */

	batman_dtack #(.CPU_14M(CPU_14M)) u_dtack (
		.clk      (clk),
		.ce_14m   (ce_14m),
		.ce_7m    (ce_7m),
		.bas      (bas),
		.wait_n   (wait_n),
		.wait2_n  (wait2_n),
		.vrwait_n (vrwait_n),
		.vpa_n    (vpa_n),
		.dtack    (dtack_163),
		.ce_cpu   (dtack_ce_cpu),
		.count    (dtack_count)
	);

	// =====================================================================
	//  the watchdog and /SYSRES
	// =====================================================================
	/* verilator lint_off UNUSEDSIGNAL */
	wire       wdog_power_on;
	wire [3:0] wdog_count;
	/* verilator lint_on UNUSEDSIGNAL */

	batman_watchdog #(
		.CLK_HZ     (CLK_HZ),
		.POR_US     (POR_US),
		.WDOG_STRAP (WDOG_STRAP)
	) u_wdog (
		.clk       (clk),
		.ext_reset (game_reset),
		.vblank    (vblank),
		.wdog_n    (wdog_n),
		.sysres_n  (sysres_n),
		.power_on  (wdog_power_on),
		.count     (wdog_count)
	);

	// =====================================================================
	//  the interrupt encoder
	// =====================================================================
	batman_irq u_irq (
		.vint_n   (vad_vint_n),
		.audirq_n (audirq_n),
		.bas      (bas),
		.fc       (fc),
		.ipl      (ipl),
		.vpa_n    (vpa_n)
	);

	// =====================================================================
	//  inputs, the status word and the LS273 1S output latch
	// =====================================================================
	// The LS273 takes data on the trailing edge of /LATCH; a read of 0x260050
	// clocks it too, with the floating bus as data.  Hold the value while the
	// strobe is low so the edge sees the 68000's data.
	logic [15:0] latch_data;
	always_ff @(posedge clk)
		if (!latch_n) latch_data <= rw ? UNDRIVEN_DATA : cpu_dout;

	wire [7:0] mux_dout;
	wire [3:0] stat_dout;

	batman_inputs u_inputs (
		.clk       (clk),
		.sysres_n  (sysres_n),
		.ma1       (a[1]),

		.p1_joy    (p1_joy),
		.p2_joy    (p2_joy),
		.p1_fire   (p1_fire),
		.p1_acta   (p1_acta),
		.p1_actb   (p1_actb),
		.p1_start  (p1_start),
		.p2_fire   (p2_fire),
		.p2_acta   (p2_acta),
		.p2_actb   (p2_actb),
		.p2_start  (p2_start),

		.audirq_n  (audirq_n),
		.audfull_n (audfull_n),
		.self_test (self_test),
		.service   (service),
		.service2  (service2),
		.vblank    (vblank),

		.mux_dout  (mux_dout),
		.stat_dout (stat_dout),

		.latch_n   (latch_n),
		.latch_d   (latch_data),
		.cc_r      (cc_r),
		.cc_l      (cc_l),
		.sndres_n  (sndres_n),
		.grbk0     (grbk0),
		.albk      (albk),
		.vcr       (vcr),
		.latch_q   (latch_q)
	);

	// =====================================================================
	//  the AUDIO-header strobes
	// =====================================================================
	// The two pulses mark the end of each strobe, which is when the LS374
	// mailbox on the sound board clocks.
	logic scomwr_n_q, scomrd_n_q;
	always_ff @(posedge clk) begin
		scomwr_n_q <= scomwr_n;
		scomrd_n_q <= scomrd_n;
		if (!scomwr_n) scom_wdata <= cpu_dout[7:0];
	end
	assign scomwr_stb = scomwr_n & ~scomwr_n_q;
	assign scomrd_stb = scomrd_n & ~scomrd_n_q;

	// =====================================================================
	//  work RAM (COM_RAM): two 32K x 8 SRAMs at 11/12R and 10/11R
	// =====================================================================
	// Word addressed by MA1..MA15; MA16 is not connected, so the 64 KB repeats
	// twice in the 128 KB /COM window.  /COM comes from the F138, so it is /AS
	// qualified (the ROM selects are not).
	logic [7:0] ram_lo [0:32767];      // D0-D7,  /WE = /WL
	logic [7:0] ram_hi [0:32767];      // D8-D15, /WE = /WU
	logic [15:0] ram_q;

	wire [14:0] ram_a = a[15:1];
	wire ram_we_lo = ~com_n & ~wl_n;
	wire ram_we_hi = ~com_n & ~wu_n;

	always_ff @(posedge clk) begin
		if (ram_we_lo) ram_lo[ram_a] <= cpu_dout[7:0];
		if (ram_we_hi) ram_hi[ram_a] <= cpu_dout[15:8];
		ram_q <= {ram_hi[ram_a], ram_lo[ram_a]};
	end

`ifndef ALTERA_RESERVED_QIS
	// Block RAM powers up at 0x00, as MAME's work RAM does.
	initial begin
		for (int i = 0; i < 32768; i++) begin
			ram_lo[i] = 8'h00;
			ram_hi[i] = 8'h00;
		end
	end
`endif

	// =====================================================================
	//  the EEPROM at 12R and the 11N/P unlock flop
	// =====================================================================
	// The EEPROM /WE is /WL on every write, so `any_write` is the rising edge of
	// /WL anywhere in the map and `cpu_we` is that edge inside the /EEPROM
	// window.  Address and data are held because /AS is gone by that edge.
	logic wl_n_q;
	always_ff @(posedge clk) wl_n_q <= wl_n;
	wire wl_rise = wl_n & ~wl_n_q;

	logic        ee_in_win;
	logic [10:0] ee_addr;
	logic  [7:0] ee_wdata;
	always_ff @(posedge clk) begin
		if (!wl_n)     ee_in_win <= ~eeprom_n;
		if (!eeprom_n) begin
			ee_addr  <= a[11:1];
			ee_wdata <= cpu_dout[7:0];
		end
	end

	// /UNLOCK drives the flop's /PRE and on the board releases slightly after
	// /WL (it comes through more gates), so it wins at the /WL edge of its own
	// cycle.  One clk_sys of stretch models that.
	logic unlock_q;
	always_ff @(posedge clk) unlock_q <= ~unlock_n;
	wire unlock_lvl = ~unlock_n | unlock_q;

	wire  [7:0] ee_rdata;
	wire        ee_write_accepted;
	/* verilator lint_off UNUSEDSIGNAL */
	wire        ee_busy, ee_oe_n, ee_unlocked;
	/* verilator lint_on UNUSEDSIGNAL */

	wire        nv_load_we, nv_seed_we, nv_load_end;
	wire [10:0] nv_load_addr, nv_dump_addr;
	wire  [7:0] nv_load_data, nv_dump_data;

	batman_eeprom_28c16 #(
		.CLK_HZ       (CLK_HZ),
		.WRITE_CYCLES (EEPROM_WRITE_CYCLES)
	) u_eeprom (
		.clk            (clk),
		.init_reset     (init_reset),
		.reset          (~sysres_n),
		.unlock         (unlock_lvl),
		.any_write      (wl_rise),
		.cpu_we         (wl_rise & ee_in_win),
		.cpu_addr       (ee_addr),
		.cpu_wdata      (ee_wdata),
		.cpu_rdata      (ee_rdata),
		.busy           (ee_busy),
		.oe_n           (ee_oe_n),
		.unlocked       (ee_unlocked),
		.write_accepted (ee_write_accepted),
		.load_we        (nv_load_we),
		.load_addr      (nv_load_addr),
		.load_data      (nv_load_data),
		.seed_we        (nv_seed_we),
		.load_end       (nv_load_end),
		.dump_addr      (nv_dump_addr),
		.dump_data      (nv_dump_data)
	);

	batman_nvram_io u_nvram (
		.clk                (clk),
		.init_reset         (init_reset),
		.write_accepted     (ee_write_accepted),
		.ioctl_download     (ioctl_download),
		.ioctl_wr           (ioctl_wr),
		.ioctl_addr         (ioctl_addr),
		.ioctl_dout         (ioctl_dout),
		.ioctl_index        (ioctl_index),
		.ioctl_upload       (ioctl_upload),
		.load_we            (nv_load_we),
		.load_addr          (nv_load_addr),
		.load_data          (nv_load_data),
		.seed_we            (nv_seed_we),
		.load_end           (nv_load_end),
		.dump_addr          (nv_dump_addr),
		.dump_data          (nv_dump_data),
		.ioctl_upload_req   (ioctl_upload_req),
		.ioctl_upload_index (ioctl_upload_index),
		.ioctl_din          (ioctl_din)
	);

	// =====================================================================
	//  the video side: one strobe and a handshake
	// =====================================================================
	assign vad_vram_n = vram_n;
	assign vad_iack   = (fc == 3'b111);
	assign vad_rw     = rw;
	assign vad_ma     = a[16:1];
	assign vad_din    = cpu_dout;
	assign vad_wl_n   = wl_n;
	assign vad_wu_n   = wu_n;

	// =====================================================================
	//  the program ROM, served from SDRAM
	// =====================================================================
	// /ROM0..2 cover 0x000000-0x0BFFFF (/ROM3 duplicates /ROM2 and its sockets
	// are empty).  The ROM selects are plain address decodes, not gated by /AS,
	// so `rom_rd` is not either; only the /DTACK stall is.
	wire rom_sel = ~(rom0_n & rom1_n & rom2_n);
	wire rom_rd  = rom_sel & rw;

	wire [15:0] prom_data;
	wire        prom_stall;
	/* verilator lint_off UNUSEDSIGNAL */
	wire        prom_ready;
	/* verilator lint_on UNUSEDSIGNAL */

	wire          c_req, c_valid, c_last;
	wire [AW-1:0] c_addr;
	wire  [1:0]   c_blen;
	wire [15:0]   c_rdata;

	batman_prog_rom #(
		.AW         (AW),
		.PROG_BASE  (PROG_BASE),
		.PAW        (19),
		.PROG_WORDS ('h60000),
		.LINES      (PROG_CACHE_LINES)
	) u_prom (
		.clk     (clk),
		.reset   (mem_reset),
		.rd      (rom_rd),
		.addr    (a[19:1]),
		.data    (prom_data),
		.ready   (prom_ready),
		.stall   (prom_stall),
		.c_req   (c_req),
		.c_addr  (c_addr),
		.c_blen  (c_blen),
		.c_valid (c_valid),
		.c_last  (c_last),
		.c_rdata (c_rdata)
	);

	// =====================================================================
	//  the download chain and the SDRAM
	// =====================================================================
	wire        ld_wr;
	wire [23:0] ld_addr;
	wire        sdl_busy;

	wire          dl_wr, dl_ack;
	wire [AW-1:0] dl_waddr;
	wire [15:0]   dl_wdata;

	batman_rom_loader u_ldr (
		.clk            (clk),
		.reset          (init_reset),
		.ioctl_download (ioctl_download),
		.ioctl_wr       (ioctl_wr),
		.ioctl_addr     (ioctl_addr),
		.ioctl_dout     (ioctl_dout),
		.ioctl_index    (ioctl_index),
		.sdram_wr       (ld_wr),
		.sdram_addr     (ld_addr),
		.char_wr        (char_wr),
		.char_addr      (char_addr),
		.snd_wr         (snd_wr),
		.snd_addr       (snd_addr),
		.rom_data       (rom_data),
		.rom_loaded     (rom_loaded)
	);

	batman_sdram_loader #(.AW(AW)) u_sdl (
		.clk      (clk),
		.reset    (init_reset),
		.ld_wr    (ld_wr),
		.ld_addr  (ld_addr),
		.ld_data  (rom_data),
		.wr_busy  (sdl_busy),
		.dl_wr    (dl_wr),
		.dl_waddr (dl_waddr),
		.dl_wdata (dl_wdata),
		.dl_ack   (dl_ack)
	);

	assign ioctl_wait = sdl_busy;

	wire          sd_req, sd_we, rfsh_ok, sd_ready, sd_valid;
	wire [AW-1:0] sd_addr;
	wire  [2:0]   sd_blen;
	wire [15:0]   sd_wdata, sd_rdata;

	batman_gfx_mem #(.AW(AW)) u_gfx (
		.clk       (clk),
		.reset     (init_reset),
		.cpu_req   (c_req),
		.cpu_addr  (c_addr),
		.cpu_blen  (c_blen),
		.cpu_valid (c_valid),
		.cpu_last  (c_last),
		.cpu_rdata (c_rdata),
		.pf1_req   (pf1_req),
		.pf1_addr  (pf1_addr),
		.pf1_ack   (pf1_ack),
		.pf1_data  (pf1_data),
		.pf1_group (pf1_group),
		.pf2_req   (pf2_req),
		.pf2_addr  (pf2_addr),
		.pf2_ack   (pf2_ack),
		.pf2_data  (pf2_data),
		.pf2_group (pf2_group),
		.mo_req    (mo_req),
		.mo_addr   (mo_addr),
		.mo_ack    (mo_ack),
		.mo_data   (mo_data),
		.mo_group  (mo_group),
		.oki_req   (oki_req),
		.oki_addr  (oki_addr),
		.oki_ack   (oki_ack),
		.oki_data  (oki_data),
		.dl_wr     (dl_wr),
		.dl_waddr  (dl_waddr),
		.dl_wdata  (dl_wdata),
		.dl_ack    (dl_ack),
		.sd_req    (sd_req),
		.sd_addr   (sd_addr),
		.sd_we     (sd_we),
		.sd_blen   (sd_blen),
		.sd_wdata  (sd_wdata),
		.rfsh_ok   (rfsh_ok),
		.sd_ready  (sd_ready),
		.sd_valid  (sd_valid),
		.sd_rdata  (sd_rdata)
	);

	batman_sdram u_sdram (
		.clk        (clk),
		.reset      (init_reset),
		.addr       (sd_addr),
		.wdata      (sd_wdata),
		.we         (sd_we),
		.blen       (sd_blen),
		.req        (sd_req),
		.rdata      (sd_rdata),
		.valid      (sd_valid),
		.ready      (sd_ready),
		.rfsh_ok    (rfsh_ok),
		.SDRAM_DQ   (SDRAM_DQ),
		.SDRAM_A    (SDRAM_A),
		.SDRAM_BA   (SDRAM_BA),
		.SDRAM_DQML (SDRAM_DQML),
		.SDRAM_DQMH (SDRAM_DQMH),
		.SDRAM_CKE  (SDRAM_CKE),
		.SDRAM_nCS  (SDRAM_nCS),
		.SDRAM_nRAS (SDRAM_nRAS),
		.SDRAM_nCAS (SDRAM_nCAS),
		.SDRAM_nWE  (SDRAM_nWE)
	);

	// =====================================================================
	//  the read mux: what drives D15:0
	// =====================================================================
	// The decodes are mutually exclusive by construction (one F138 output,
	// one LS138 output), so this is a priority chain only to be explicit.
	// Every lane nothing drives is UNDRIVEN_DATA.
	always_comb begin
		cpu_rdata = UNDRIVEN_DATA;
		if      (rom_sel)    cpu_rdata = prom_data;                          // 27C010 pairs
		else if (!com_n)     cpu_rdata = ram_q;                              // COM_RAM
		else if (!eeprom_n)  cpu_rdata = {UNDRIVEN_DATA[15:8], ee_rdata};    // 12R, odd byte
		else if (!vram_n)    cpu_rdata = vad_dout;                           // the VAD
		else if (!plsws_n)   cpu_rdata = {mux_dout, UNDRIVEN_DATA[7:0]};     // 1P/2P
		// 2S drives only D7:4; D3:0 and D15:8 float
		else if (!status_n)  cpu_rdata = {UNDRIVEN_DATA[15:8], stat_dout,
		                                  UNDRIVEN_DATA[3:0]};
		else if (!scomrd_n)  cpu_rdata = {UNDRIVEN_DATA[15:8], scom_rdata};  // AUDIO 6-13
	end

	assign cpu_din = cpu_rdata;

	// =====================================================================
	//  /DTACK into the CPU
	// =====================================================================
	// The F163's RCO, held off while the program-ROM cache misses.
	assign dtack = dtack_163 & ~(bas & rom_rd & prom_stall);

	// =====================================================================
	//  observability
	// =====================================================================
	assign cpu_a     = a;
	assign cpu_as    = as;
	assign cpu_rw    = rw;
	assign cpu_uds_n = uds_n;
	assign cpu_lds_n = lds_n;
	assign cpu_wdata = cpu_dout;
	assign cpu_fc    = fc;
	assign cpu_dtack = dtack;

	// Nets with no load here: three unused F138 windows, two unused LS138
	// strobes, the duplicate /ROM3, the F138 enable and /CIO (both used inside
	// batman_decode) and the CPU clock tick.
	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused_main = &{1'b0,
	                      rom3_n, ioen_n, cio_n,
	                      f138_y2_n, f138_y4_n, f138_y6_n,
	                      ls138_y2_n, ls138_y7_n,
	                      ce_cpu,
	                      1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
