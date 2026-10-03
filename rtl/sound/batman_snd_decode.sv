`timescale 1ns/1ps
//============================================================================
//  Batman (Atari Games, 1990/91) - JSA III audio board A048974-01: the whole
//  6502 address decode.  GAL 136085-1038 at 17C, the LS138 at 18C, and the
//  /VOL strobe from GAL 136085-1039 at 20C, as the schematic draws them.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.  See LICENSE, NOTICE.md.
//
//  Structure follows the Skull & Crossbones core's skullxbo_snd_decode.sv
//  (GPL-3.0); see NOTICE.md.  The equations are Batman's own (the two GAL
//  modules) and the LS138 wiring is this board's.  GAL 20C is instantiated
//  once, here, because /VOL is part of this address map; its other outputs
//  are passed out to the blocks that use them.
//
//  Address map:
//   $0000-$1FFF      R/W  8 KB RAM 15C
//   $2000-$27FF      R/W  YM2151, A0 = SA0
//   $2800 +0,2,4,6   stb  /RDV /RDP /RDIO /IRQACK   (SA9 = 0)
//   $2A00 +0,2,4,6   stb  /WRV /WRP /WRIO /MIX      (SA9 = 1)
//   $2900-$29FF      stb  /VOL (SA8 = 1; mirrors at $2B00/$2D00/$2F00)
//   $2C00, $2E00     -    nothing (SA10 = 1 disables 18C, SA8 = 0 blocks /VOL)
//   $3000-$3FFF      R    banked ROM window {BA13,BA12,SA11:0}
//   $4000-$FFFF      R    fixed program ROM 12C
//
//  Board details that differ from MAME and must be kept:
//   - The LS138 strobes ignore R/W: G1 is REST (O2 & $2800-$2FFF) and /VOL is
//     REST & SA8.  Only SA9 separates the "read" and "write" groups.
//   - /G2A = SA10 and /G2B = SA8; SA0 is not decoded, so $2803 acks the IRQ
//     like $2806.  The master volume is on the SA8 = 1 pages, not at $2800.
//   - Three of /SRD's four GAL terms only act inside $2800-$2FFF, where nothing
//     that uses /SRD is selected.  srd is the effective form (SR/W & O2) and
//     srd_gal the literal pin.
//   - 12C uses /CE = /SRD and /OE = /ROM (the reverse of the JSA II board).
//
//  O2: one ce_1m79 pulse is one 6502 bus cycle, so o2 = ce_1m79.  /RAM, /YAM,
//  /ROM, A13B and A12B carry no O2; they are address decodes valid for the
//  whole cycle.  The LS174/LS273 latches clock when their strobe rises at the
//  end of O2, which is modelled as "latch on the ce_1m79 where the strobe is 1".
//============================================================================

module batman_snd_decode
(
	// ================= GAL 17C - the 6502 side ==========================
	input  logic [15:0] sa,          // SA15..SA0
	input  logic        srw,         // SR//W, 1 = read      -- 17C pin 1
	input  logic        o2,          // O2 (6502 pin 39)     -- 17C pin 2
	input  logic        ba13,        // 10A LS273 bit 7      -- 17C pin 4
	input  logic        ba12,        // 10A LS273 bit 6      -- 17C pin 3

	// ================= GAL 20C - its other three jobs ===================
	input  logic        okb0,        // 10A LS273 bit 1      -- 20C pin 6
	input  logic        okb1,        // 8A  LS174 bit 4      -- 20C pin 7
	input  logic        va17,        // MSM6295 pin 35       -- 20C pin 8
	input  logic        va16,        // MSM6295 pin 34       -- 20C pin 9 (spare)
	input  logic        ms4irq,      // 18B/2 Q = 4MSIRQ     -- 20C pin 1
	input  logic        lvl_3579k,   // level model of 3579K -- 20C pin 4
	input  logic        lvl_1193k,   // level model of 1193K -- 20C pin 5

	// ---- 17C outputs, as active-high "asserted" nets ----
	output logic        rom_ce,      // /ROM  (pin 19) -- read-qualified, no O2
	output logic        yam,         // /YAM  (pin 18)
	output logic        rest,        // REST  (pin 17) -- O2 & $2800-$2FFF
	output logic        ram,         // /RAM  (pin 16)
	output logic        a13b,        // A13B  (pin 15) -- 12C A13, positive sense
	output logic        a12b,        // A12B  (pin 14) -- 12C A12, positive sense
	output logic        swr,         // /SWR  (pin 13)
	output logic        srd,         // /SRD  -- effective form, SR/W & O2
	output logic        srd_gal,     // /SRD  -- the literal pin

	// ---- address-only windows (no O2, no direction) ----
	output logic        sel_ram,     // $0000-$1FFF  -> 15C
	output logic        sel_ym,      // $2000-$27FF  -> YM2151 (= yam)
	output logic        sel_bank,    // $3000-$3FFF  -> 12C, A13/A12 = BA13/BA12
	output logic        sel_romfix,  // $4000-$FFFF  -> 12C straight through
	output logic        sel_dead,    // $2C00-$2CFF and $2E00-$2EFF: nothing

	// ---- LS138 18C, active high, O2-qualified, no direction term ----
	output logic        sel_rdv,     // Y0 $2800  /RDV     MSM6295 /RD
	output logic        sel_rdp,     // Y1 $2802  /RDP     14A /OC; clears /AUDFULL
	output logic        sel_rdio,    // Y2 $2804  /RDIO    LS240 13A /G x2
	output logic        sel_irqack,  // Y3 $2806  /IRQACK  18B/2 /CLR
	output logic        sel_wrv,     // Y4 $2A00  /WRV     MSM6295 /WR
	output logic        sel_wrp,     // Y5 $2A02  /WRP     16A CLK; sets /AUDIRQ
	output logic        sel_wrio,    // Y6 $2A04  /WRIO    10A LS273 CLK
	output logic        sel_mix,     // Y7 $2A06  /MIX     8A LS174 CLK

	// ---- GAL 20C pin 19 ----
	output logic        sel_vol,     // /VOL $29xx -> 7C LS273 CLK

	// ---- GAL 20C, passed out to the blocks that use them ----
	output logic  [3:0] rom_n,       // {/ROM3,/ROM2,/ROM1,/ROM0}, active low
	output logic        romn_n,      // /ROMN -> 17E/19E pin 30 (NC)
	output logic        clk1193,     // CLK1193 (diagnostic only)
	output logic        irq_gal_lo,  // pin 18 is pulling /IRQ down

	// ---- misc ----
	output logic        ym_a0,       // YM2151 pin 4 = SA0
	output logic [15:0] rom_addr     // 12C A15..A0 = {SA15,SA14,A13B,A12B,SA11:0}
);

	// ========================================================================
	//  GAL 136085-1038 at 17C
	// ========================================================================
	wire g17_srd, g17_swr, g17_a12b, g17_a13b, g17_ram, g17_rest, g17_yam, g17_rom;
	batman_gal_17c u_gal17c (
		.p1 (srw),    .p2 (o2),     .p3 (ba12),   .p4 (ba13),   .p5 (sa[9]),
		.p6 (sa[11]), .p7 (sa[12]), .p8 (sa[13]), .p9 (sa[14]), .p11(sa[15]),
		.p12(g17_srd), .p13(g17_swr), .p14(g17_a12b), .p15(g17_a13b),
		.p16(g17_ram), .p17(g17_rest), .p18(g17_yam), .p19(g17_rom) );

	// The pins are active low except 16 and 17; these nets are "asserted = 1".
	assign srd_gal = ~g17_srd;
	assign swr     = ~g17_swr;
	assign a12b    =  g17_a12b;    // A12B / A13B are positive-sense address
	assign a13b    =  g17_a13b;    // bits: the pin is the ROM's A12 / A13.
	assign ram     = ~g17_ram;     // pin 16 is active high = SA13|SA14|SA15
	assign rest    =  g17_rest;    // pin 17 is active high
	assign yam     = ~g17_yam;
	assign rom_ce  = ~g17_rom;

	// Effective /SRD: differs from srd_gal only inside $2800-$2FFF, where no
	// /SRD consumer is selected.
	assign srd = srw & o2;

	// ========================================================================
	//  GAL 136085-1039 at 20C
	// ========================================================================
	wire g20_romn, g20_rom0, g20_rom1, g20_rom2, g20_rom3;
	wire g20_clk1193, g20_irq_oe, g20_irq_lo, g20_vol;
	batman_gal_20c u_gal20c (
		.p1 (ms4irq), .p2 (rest),   .p3 (sa[8]),  .p4 (lvl_3579k), .p5 (lvl_1193k),
		.p6 (okb0),   .p7 (okb1),   .p8 (va17),   .p9 (va16),      .p11(g20_romn),
		.p12(g20_romn), .p13(g20_rom0), .p14(g20_rom1), .p15(g20_rom2),
		.p16(g20_rom3), .p17(g20_clk1193),
		.p18_oe(g20_irq_oe), .p18_lo(g20_irq_lo), .p19(g20_vol) );

	assign rom_n     = { g20_rom3, g20_rom2, g20_rom1, g20_rom0 };
	assign romn_n    = g20_romn;
	assign clk1193   = g20_clk1193;
	// Low-side driver onto the wired-AND /IRQ: active only while the pin is
	// enabled and driving 0.
	assign irq_gal_lo = g20_irq_oe & ~g20_irq_lo;
	assign sel_vol    = ~g20_vol;

	// ========================================================================
	//  the address windows the memories see
	// ========================================================================
	assign sel_ram    = ram;                        // $0000-$1FFF
	assign sel_ym     = yam;                        // $2000-$27FF (mirror $07FE)
	assign sel_bank   = (sa[15:12] == 4'h3);        // $3000-$3FFF
	assign sel_romfix = (sa[15:14] != 2'b00);       // $4000-$FFFF

	// ========================================================================
	//  LS138 18C
	//     G1 (6) = REST (active high)   /G2A (4) = SA10   /G2B (5) = SA8
	//     C,B,A (3,2,1) = SA9, SA2, SA1
	// ========================================================================
	wire       en138 = rest & ~sa[10] & ~sa[8];
	wire [2:0] s138  = { sa[9], sa[2], sa[1] };
	wire [7:0] y138  = en138 ? (8'h01 << s138) : 8'h00;

	assign sel_rdv    = y138[0];
	assign sel_rdp    = y138[1];
	assign sel_rdio   = y138[2];
	assign sel_irqack = y138[3];
	assign sel_wrv    = y138[4];
	assign sel_wrp    = y138[5];
	assign sel_wrio   = y138[6];
	assign sel_mix    = y138[7];

	// Pages in $2800-$2FFF that select nothing: SA10 = 1 disables the LS138
	// and SA8 = 0 blocks /VOL.  rest already carries O2 and the page test.
	assign sel_dead = rest & sa[10] & ~sa[8];

	assign ym_a0    = sa[0];
	assign rom_addr = { sa[15], sa[14], a13b, a12b, sa[11:0] };

	// SA3..SA7 are not decoded in the LS138 window; they still reach the
	// memories through sa.
	wire _unused_dec = &{ 1'b0, sa[7:3] };

endmodule
