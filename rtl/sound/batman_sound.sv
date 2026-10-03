`timescale 1ns/1ps
//============================================================================
//  Batman (Atari Games, 1990/91) - the whole JSA III audio board A048974-01,
//  plus the sound side of the 36-pin audio header to the game board.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.  See LICENSE, NOTICE.md.
//
//  Structure follows the Skull & Crossbones core's skullxbo_sound.sv (GPL-3.0).
//  Submodules:
//    batman_snd_decode    GAL 17C + LS138 18C + GAL 20C (address decode)
//    batman_snd_io        latches 10A / 8A / 7C, input port 13A, coin counters
//    batman_snd_mailbox   LS374 16A / 14A + F74 17B, both directions
//    batman_snd_irq       LS393 19A / 20A + LS74 18B, 4 ms timer and /IRQ
//    batman_snd_adpcm     MSM6295 10E + four 27C010 sample ROMs
//    batman_ym            YM2151 9C1 + YM3012 8D (jt51)
//    batman_snd_mix       the analogue filters and mixer, in fixed point
//  Here directly: the 6502A at 11C (T65), 8 KB RAM 15C, 64 KB program ROM 12C
//  with its $3000 bank window, and the SD7:0 read mux.
//
//  Clocks: the board has no oscillator; 3579K comes from the game board.
//    ce_3m58 = clk_sys/16  3.579545 MHz  YM2151, LS393 chain
//    ce_1m79 = clk_sys/32  1.789773 MHz  6502 clock; also used as O2
//    ce_1m19 = clk_sys/48  1.193182 MHz  MSM6295 XT
//  ce_1m79 must be a subset of ce_3m58 (jt51 requirement); one counter in
//  batman_clocks guarantees it.  The board makes 1193K with an XOR feedback
//  loop in GAL 20C; the core uses the equivalent integer enable instead.
//
//  Reset: the board has no reset circuit.  /RESET is a level from the game
//  board's LS273 1S; here it is (por | sndres).  It resets the 6502 and
//  latches 8A, 10A and 7C only, not the mailbox flags or the timer flop.
//
//  Not on this board: no YM2413 (site 9C2 empty), YM2151 CT1/CT2 unconnected
//  (MAME uses CT1 to gate the OKI), no wait states, one MSM6295 only.
//  Output is mono (AUDOUT); the volume pot and TDA2030 amplifier are left to
//  the MiSTer volume control.
//============================================================================

module batman_sound
#(
	// Test only.  0 = the board's /RDIO byte.  1 = MAME's inverted bit 6,
	// for byte-for-byte comparison with MAME.
	parameter bit MAME_RDIO_POLARITY = 1'b0,
	// Test only.  1 = MAME's free-running periodic IRQ instead of the board's
	// ack-gated divider.
	parameter bit MAME_IRQ_FREERUN   = 1'b0
)
(
	input  logic        clk,
	input  logic        ce_3m58,        // 3579K : YM2151 clock, the LS393 chain
	input  logic        ce_1m79,        // 1790K : 6502 phi0 / O2
	input  logic        ce_1m19,        // 1193K : MSM6295 XT
	input  logic        por,            // FPGA power-up / download hold

	// ================= the audio header to the game board ===================
	input  logic        scom_wr,        // pin 5  /SCOM-WR = /AUDWR, 1 clk
	input  logic  [7:0] scom_wr_data,   // pins 6-13 D7..D0 for that write
	input  logic        scom_rd,        // pin 4  /SCOM-RD = /AUDRD, 1 clk
	output logic  [7:0] scom_rd_data,   // pins 6-13, 16A's Q
	output logic        audirq_n,       // pin 3  -> /IPL1 (level 6), /STATUS D4
	output logic        audfull_n,      // pin 2  -> /STATUS D5
	input  logic        sndres,         // pin 1  /SNDRES asserted (1 = held)

	// ---- board inputs, active high = "closed / pressed" ----
	input  logic        self_test,      // pin 20 the shared /SELFTEST node
	input  logic        service,        // pin 22 /SERVICE  (JAMMA-R)
	input  logic        tilt,           // pin 21 /TILT     (JAMMA-S)
	input  logic        coin_l,         // pin 17 /COINL    (JAMMA-16)
	input  logic        coin_r,         // pin 19 /COINR    (JAMMA-T)

	// ---- coin counters ----
	output logic        cctr1,          // pin 28 /CCNTRL
	output logic        cctr2,          // pin 27 /CCNTRR
	output logic        cctr_wired_or,  // the node R18 = 0 ohm makes of them

	// ---- 6502 program-ROM load port (from the MiSTer ROM loader) ----
	input  logic        rom_wr,
	input  logic [15:0] rom_addr,
	input  logic  [7:0] rom_data,

	// ---- MSM6295 sample-ROM client: 512 KB, offset within the region ----
	output logic        oki_req,
	output logic [18:0] oki_addr,
	input  logic        oki_ack,
	input  logic  [7:0] oki_data,

	// ---- audio (mono: both outputs carry the same sample) ----
	output logic signed [15:0] audio_l,
	output logic signed [15:0] audio_r,

	// ================= diagnostics ==========================================
	// Observation only; they cost nothing when left unconnected.
	output logic [15:0] dbg_cpu_addr,
	output logic  [7:0] dbg_cpu_dout,
	output logic  [7:0] dbg_cpu_din,
	output logic        dbg_cpu_rnw,
	output logic        dbg_cpu_sync,
	output logic        dbg_o2,         // = ce_1m79
	output logic  [7:0] dbg_sel,        // {MIX,WRIO,WRP,WRV,IRQACK,RDIO,RDP,RDV}
	output logic        dbg_sel_vol,
	output logic        dbg_irq_n,
	output logic        dbg_nmi_n,
	output logic        dbg_ms4irq,
	output logic        dbg_clipped
);

	// ========================================================================
	//  /RESET - header pin 1.  Reaches 11C, 8A, 10A, 7C and nothing else.
	// ========================================================================
	wire reset_n = ~(por | sndres);

	// ========================================================================
	//  level models of the two clock nets on GAL 20C pins 4 and 5
	// ========================================================================
	// Square waves for the GAL's CLK1193 = 3579K XOR 1193K term.  The result
	// is diagnostic only; the core uses ce_1m19 as the 1193K clock.
	logic lvl_3579k, lvl_1193k;
	initial begin lvl_3579k = 1'b0; lvl_1193k = 1'b0; end
	always @(posedge clk) begin
		if (ce_3m58) lvl_3579k <= ~lvl_3579k;
		if (ce_1m19) lvl_1193k <= ~lvl_1193k;
	end

	// ========================================================================
	//  the 6502 bus nets
	// ========================================================================
	wire [15:0] cpu_addr;
	wire  [7:0] cpu_dout;
	wire        cpu_rnw, cpu_sync;
	logic [7:0] cpu_din;

	wire rom_ce, yam, rest, ram, a13b, a12b, swr, srd, srd_gal;
	wire sel_ram, sel_ym, sel_bank, sel_romfix, sel_dead;
	wire sel_rdv, sel_rdp, sel_rdio, sel_irqack;
	wire sel_wrv, sel_wrp, sel_wrio, sel_mix, sel_vol;
	wire [3:0] rom_n;
	wire romn_n, clk1193, irq_gal_lo, ym_a0;
	wire [15:0] rom_rd_addr;

	wire [1:0] bank;
	wire       vfreq, okires_n, okb0, yamres_n, lpf, okb1, sp0;
	wire [2:0] ym_vol;
	wire [6:0] vol;
	wire [7:0] rdio_data;
	wire       va17, va16, ms4irq;

	// ========================================================================
	//  GAL 17C + LS138 18C + GAL 20C
	// ========================================================================
	batman_snd_decode u_dec (
		.sa(cpu_addr), .srw(cpu_rnw), .o2(ce_1m79),
		.ba13(bank[1]), .ba12(bank[0]),
		.okb0(okb0), .okb1(okb1), .va17(va17), .va16(va16), .ms4irq(ms4irq),
		.lvl_3579k(lvl_3579k), .lvl_1193k(lvl_1193k),
		.rom_ce(rom_ce), .yam(yam), .rest(rest), .ram(ram),
		.a13b(a13b), .a12b(a12b), .swr(swr), .srd(srd), .srd_gal(srd_gal),
		.sel_ram(sel_ram), .sel_ym(sel_ym), .sel_bank(sel_bank),
		.sel_romfix(sel_romfix), .sel_dead(sel_dead),
		.sel_rdv(sel_rdv), .sel_rdp(sel_rdp), .sel_rdio(sel_rdio),
		.sel_irqack(sel_irqack), .sel_wrv(sel_wrv), .sel_wrp(sel_wrp),
		.sel_wrio(sel_wrio), .sel_mix(sel_mix), .sel_vol(sel_vol),
		.rom_n(rom_n), .romn_n(romn_n), .clk1193(clk1193),
		.irq_gal_lo(irq_gal_lo),
		.ym_a0(ym_a0), .rom_addr(rom_rd_addr) );

	// ========================================================================
	//  LS374 16A / 14A + F74 17B - the mailbox
	// ========================================================================
	wire [7:0] rdp_data;
	wire       audfull, audirq, nmi_n;
	batman_snd_mailbox u_mbx (
		.clk(clk),
		.scom_wr(scom_wr), .scom_wr_data(scom_wr_data),
		.scom_rd(scom_rd), .scom_rd_data(scom_rd_data),
		.audirq_n(audirq_n), .audfull_n(audfull_n), .sndres(sndres),
		.sel_rdp(sel_rdp), .sel_wrp(sel_wrp), .sd(cpu_dout),
		.rdp_data(rdp_data), .nmi_n(nmi_n),
		.audfull(audfull), .audirq(audirq) );

	// ========================================================================
	//  LS273 10A / LS174 8A / LS273 7C / LS240 13A
	// ========================================================================
	// The strobes ignore R/W, so the latches capture whatever is on SD7:0.  On
	// a read of a write address that is the floating bus, modelled as the
	// bus-hold value sd_last below.
	wire [7:0] sd_bus;
	batman_snd_io u_io (
		.clk(clk), .reset_n(reset_n),
		.wrio_stb(sel_wrio), .mix_stb(sel_mix), .vol_stb(sel_vol), .sd(sd_bus),
		.self_test(self_test), .service(service), .tilt(tilt),
		.coin_l(coin_l), .coin_r(coin_r),
		.audfull(audfull), .audirq(audirq),
		.mame_polarity(MAME_RDIO_POLARITY),
		.bank(bank), .cctr2(cctr2), .cctr1(cctr1),
		.cctr_wired_or(cctr_wired_or),
		.vfreq(vfreq), .okires_n(okires_n), .okb0(okb0), .yamres_n(yamres_n),
		.lpf(lpf), .okb1(okb1), .ym_vol(ym_vol), .sp0(sp0),
		.vol(vol), .rdio_data(rdio_data) );

	// ========================================================================
	//  LS393 19A / 20A + LS74 18B - the 4 ms ack-gated timer
	// ========================================================================
	wire ym_irq, irq_n, irq_pre_tick;
	batman_snd_irq #(.MAME_FREERUN(MAME_IRQ_FREERUN)) u_irq (
		.clk(clk), .ce_3m58(ce_3m58), .por(por),
		.sel_irqack(sel_irqack), .ym_irq(ym_irq), .irq_gal_lo(irq_gal_lo),
		.ms4irq(ms4irq), .irq_n(irq_n), .dbg_pre_tick(irq_pre_tick) );

	// ========================================================================
	//  6502A 11C on T65
	// ========================================================================
	// Mode 00 = NMOS 6502, enabled on ce_1m79.  RDY and SO are strapped high,
	// so there are no wait states.  /NMI is the mailbox flag level; /IRQ is the
	// wired-AND of the timer and the YM2151.
	wire [7:0] dbgA_nc, dbgX_nc, dbgY_nc, dbgS_nc, dbgP_nc;
	T65_wrap u_cpu (
		.Mode(2'b00), .Res_n(reset_n), .Clk(clk), .Enable(ce_1m79), .Rdy(1'b1),
		.IRQ_n(irq_n), .NMI_n(nmi_n), .DI(cpu_din),
		.A(cpu_addr), .DO(cpu_dout), .R_W_n(cpu_rnw), .Sync(cpu_sync),
		.dbg_A(dbgA_nc), .dbg_X(dbgX_nc), .dbg_Y(dbgY_nc),
		.dbg_S(dbgS_nc), .dbg_P(dbgP_nc) );

	// ========================================================================
	//  MS6264L 15C (8 KB work RAM) and the 64 KB program ROM at 12C
	// ========================================================================
	//  15C (MS6264L, 8K x 8) at $0000-$1FFF: /CS1 = /RAM, /WE = /SWR, /OE = /SRD.
	//  12C (64K x 8, 136085-1040): /CE = /SRD, /OE = /ROM; A13/A12 = A13B/A12B.
	//  $4000-$FFFF reads the ROM directly; $3000-$3FFF is a 4 KB window onto ROM
	//  $0000-$3FFF selected by {BA13,BA12}, the only way to reach that part.
	//  MiSTer: the ROM is in BRAM (keeping the 6502 off SDRAM), filled by the
	//  ROM loader.  Keep separate RAM and ROM output registers; sharing one
	//  stops Quartus using M10K blocks.
	(* ramstyle = "no_rw_check, M10K" *) logic [7:0] ram_mem [0:8191];
	(* ramstyle = "no_rw_check, M10K" *) logic [7:0] rom_mem [0:65535];
`ifndef ALTERA_RESERVED_QIS
	// Sim-only zero fill so iverilog / Verilator never read X out of an
	// unwritten location.  Quartus zeroes M10K contents at configuration.
	initial begin
		for (int i = 0; i < 8192;  i++) ram_mem[i] = 8'h00;
		for (int i = 0; i < 65536; i++) rom_mem[i] = 8'h00;
	end
`endif

	// Both arrays are read every clk from the stable 6502 address, so their
	// registered outputs are ready when T65 samples DI on ce_1m79.
	logic [7:0] ram_q, rom_q;
	always @(posedge clk) begin
		if (swr & sel_ram) ram_mem[cpu_addr[12:0]] <= cpu_dout;
		ram_q <= ram_mem[cpu_addr[12:0]];
		rom_q <= rom_mem[rom_rd_addr];
		if (rom_wr) rom_mem[rom_addr] <= rom_data;
	end

	// ========================================================================
	//  YM2151 9C1 + YM3012 8D
	// ========================================================================
	// /CS = /YAM has no O2 or R/W term; only /WR (/SWR) and /RD (/SRD) carry
	// O2.  The YM2151 clock is the full 3.579545 MHz.
	wire signed [15:0] ym_ch1, ym_ch2;
	wire        [7:0]  ym_din;
	wire               ym_sample;
	// The instance must be named u_ym: Batman.sdc refers to
	// *u_sound|u_ym|u_jt51|*.
	batman_ym u_ym (
		.clk(clk), .cen(ce_3m58), .cen_p1(ce_1m79), .yamres_n(yamres_n),
		.ym_cs(sel_ym), .ym_a0(ym_a0), .ym_we(sel_ym & swr),
		.ym_dout(cpu_dout), .ym_din(ym_din), .ym_irq(ym_irq),
		.sample(ym_sample), .aud_ch1(ym_ch1), .aud_ch2(ym_ch2) );

	// ========================================================================
	//  MSM6295 10E + the four 27C010s behind GAL 20C
	// ========================================================================
	wire [7:0] rdv_data;
	wire signed [15:0] oki_audio;
	batman_snd_adpcm u_adpcm (
		.clk(clk), .ce_1m19(ce_1m19), .okires_n(okires_n), .vfreq(vfreq),
		.wr_stb(sel_wrv), .wr_data(sd_bus), .rd_stb(sel_rdv), .rd_data(rdv_data),
		.va17(va17), .va16(va16), .rom_n(rom_n), .romn_n(romn_n),
		.oki_req(oki_req), .oki_addr(oki_addr),
		.oki_ack(oki_ack), .oki_data(oki_data),
		.audio(oki_audio) );

	// ========================================================================
	//  the SD7:0 read mux
	// ========================================================================
	// Each source is gated by the strobes that enable its output on the board.
	// The MSM6295's /CS is tied low, so /RDV alone enables its status byte.
	logic [7:0] sd_drv;
	logic       sd_hit;
	always_comb begin
		sd_hit = 1'b1;
		if      (srd & sel_ram) sd_drv = ram_q;
		else if (srd & rom_ce)  sd_drv = rom_q;
		else if (srd & sel_ym)  sd_drv = ym_din;
		else if (sel_rdp)       sd_drv = rdp_data;
		else if (sel_rdio)      sd_drv = rdio_data;
		else if (sel_rdv)       sd_drv = rdv_data;
		else begin sd_drv = 8'h00; sd_hit = 1'b0; end
	end

	// Bus hold.  Nothing drives SD7:0 on an /IRQACK access, a read of the
	// $2A00 group or $29xx, or the $2C00/$2E00 dead pages, and there are no
	// pull-ups.  Keep the last byte driven, as a floating bus does for the
	// short time that matters.  This is also what a latch strobed by a read
	// (e.g. of $2A04) captures.
	logic [7:0] sd_last;
	initial sd_last = 8'h00;
	// Plain always, not always_ff: no reset, power-up value from the initial.
	always @(posedge clk) if (ce_1m79) begin
		if      (~cpu_rnw) sd_last <= cpu_dout;
		else if (sd_hit)   sd_last <= sd_drv;
	end

	assign cpu_din = sd_hit ? sd_drv : sd_last;
	// What the write-only latches and the MSM6295 host port see: the 6502's
	// byte on a write, the held bus on a read (no device drives during the
	// "write" group strobes).  Using sd_last, not the live read mux, also
	// avoids a combinational loop through the mux.
	assign sd_bus  = cpu_rnw ? sd_last : cpu_dout;

	// ========================================================================
	//  the analogue chain
	// ========================================================================
	wire signed [15:0] aud;
	wire        aud_clipped;
	wire signed [15:0] dbg_ym_lad, dbg_ym, dbg_oki_s2, dbg_oki_s3, dbg_oki,
	                   dbg_premix;
	batman_snd_mix u_mix (
		.clk(clk), .ce(ce_1m79), .reset(por), .bypass(1'b0),
		.ym_vol(ym_vol), .lpf(lpf), .sp0(sp0), .vol(vol),
		.ym_ch1(ym_ch1), .ym_ch2(ym_ch2), .oki_in(oki_audio),
		.out(aud), .clipped(aud_clipped),
		.dbg_ym_lad(dbg_ym_lad), .dbg_ym(dbg_ym), .dbg_oki_s2(dbg_oki_s2),
		.dbg_oki_s3(dbg_oki_s3), .dbg_oki(dbg_oki), .dbg_premix(dbg_premix) );

	// Mono: AUDOUT on header pin 24 is the only output this kit uses.
	assign audio_l = aud;
	assign audio_r = aud;

	// ========================================================================
	//  diagnostics
	// ========================================================================
	assign dbg_cpu_addr = cpu_addr;
	assign dbg_cpu_dout = cpu_dout;
	assign dbg_cpu_din  = cpu_din;
	assign dbg_cpu_rnw  = cpu_rnw;
	assign dbg_cpu_sync = cpu_sync;
	assign dbg_o2       = ce_1m79;
	assign dbg_sel      = { sel_mix, sel_wrio, sel_wrp, sel_wrv,
	                        sel_irqack, sel_rdio, sel_rdp, sel_rdv };
	assign dbg_sel_vol  = sel_vol;
	assign dbg_irq_n    = irq_n;
	assign dbg_nmi_n    = nmi_n;
	assign dbg_ms4irq   = ms4irq;
	assign dbg_clipped  = aud_clipped;

	// Nets kept for visibility but not used: the literal /SRD pin, raw GAL
	// pins already applied through the strobes and rom_rd_addr, the address
	// windows, GAL 20C's CLK1193, ym_sample, the filter taps and T65 debug.
	wire _unused_snd = &{ 1'b0, srd_gal, rest, ram, yam, a13b, a12b,
	                      sel_bank, sel_romfix, sel_dead, clk1193, ym_sample,
	                      irq_pre_tick,
	                      dbg_ym_lad, dbg_ym, dbg_oki_s2, dbg_oki_s3, dbg_oki,
	                      dbg_premix,
	                      dbgA_nc, dbgX_nc, dbgY_nc, dbgS_nc, dbgP_nc };

endmodule
