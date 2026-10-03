// Adapted for Batman from the Skull & Crossbones core's rtl/main/skullxbo_cpu.sv (GPL-3.0); see NOTICE.md
`timescale 1ns/1ps
//============================================================================
//  Batman main CPU: fx68k (cycle-exact 68000) wired as the MC68000 at 6L/M.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.  fx68k is Jorge Cwik's core
//  (GPL-3.0-or-later), vendored unchanged in rtl/lib/fx68k/.
//
//  CPU clock: the board picks it with solder jumpers SP3 (7MHZ) / SP4 (CLK).
//  MAME runs the CPU at 14.318 MHz; sibling Atari boards use 7.16 MHz.  This
//  core follows MAME (CPU_14M = 1); batman_dtack must get the same value
//  because its wait counter is clocked from the same node.
//  fx68k needs enPhi1/enPhi2 half a CPU clock apart (2 clk_sys at 14.3 MHz,
//  4 at 7.16 MHz).
//
//  Differences from the board: HALTn is tied inactive (fx68k's extReset does
//  the full reset), pwrUp follows reset, and BERRn/BRn/BGACKn are tied high
//  as on the board (no bus error, no other bus master).  A22/A23 are not
//  connected on the board, so the map repeats four times in 16 MB.
//  /VPA = NAND(BAS, FC2:0) makes every interrupt autovectored.
//============================================================================

module batman_cpu #(
	// 1 = 14.318 MHz (ce_14m, as MAME), 0 = 7.159 MHz (ce_7m).  Must match batman_dtack.
	parameter bit CPU_14M = 1'b1
)(
	input  logic        clk,        // clk_sys, 57.272727 MHz
	input  logic        ce_14m,     // clk_sys/4 -- CPUCLK if SP4 `CLK` is stuffed
	input  logic        ce_7m,      // clk_sys/8 -- CPUCLK if SP3 `7MHZ` is stuffed
	input  logic        reset,      // active high: /SYSRES (watchdog) + power-up

	input  logic  [2:0] ipl,        // {/IPL2,/IPL1,/IPL0}, ACTIVE LOW, 111 = none

	output logic [23:1] a,
	output logic [15:0] wdata,
	input  logic [15:0] rdata,
	output logic        as,         // ACTIVE HIGH copy of /AS (BAS, via the 12M LS04)
	output logic        uds_n,
	output logic        lds_n,
	output logic        rw,         // 1 = read, 0 = write
	input  logic        dtack,      // ACTIVE HIGH (= ~/DTACK)
	input  logic        vpa_n,      // from the 7D LS20 /VPA gate, active low
	output logic  [2:0] fc,
	output logic        reset_inst, // 1 while a RESET instruction runs (unused by batman_main)

	// CPUCLK rising tick, shared with the batman_dtack wait counter
	output logic        ce_cpu
);

	// ------------------------------------------------------- clock phases
	// The CPUCLK tick reloads pcnt with 1, so pcnt == 0 in that cycle and
	// enPhi2 lands half a CPU period later.
	wire ce_cpu_i = CPU_14M ? ce_14m : ce_7m;

	logic [2:0] pcnt;
	always_ff @(posedge clk) begin
		if (ce_cpu_i) pcnt <= 3'd1;
		else          pcnt <= pcnt + 3'd1;
	end

	wire en_phi1 = ce_cpu_i;                                  // CPUCLK rising
	wire en_phi2 = CPU_14M ? (pcnt == 3'd2) : (pcnt == 3'd4); // half a period later
	assign ce_cpu = en_phi1;

	// ------------------------------------------------------------------ IPL
	// fx68k resynchronises IPL internally, so plain posedge staging is fine.
	// Reset value 111 = no interrupt.
	logic [2:0] ipl_r, ipl_rr;
	always_ff @(posedge clk) begin
		if (reset) begin
			ipl_r  <= 3'b111;
			ipl_rr <= 3'b111;
		end else begin
			ipl_r  <= ipl;
			ipl_rr <= ipl_r;
		end
	end

	// ---------------------------------------------------------------- fx68k
	wire        fx_as_n, fx_reset_n;
	wire [23:1] fx_eab;

	/* verilator lint_off UNUSEDSIGNAL */
	wire        fx_e, fx_vma_n;    // 6800 bus: pins 19, 20 unconnected
	wire        fx_bg_n;           // pin 11 unconnected, no second master
	wire        fx_halted_n;       // double bus fault; no load on the board
	/* verilator lint_on UNUSEDSIGNAL */

	assign a          = fx_eab;
	assign as         = ~fx_as_n;
	assign reset_inst = ~fx_reset_n;

	fx68k u_fx68k (
		.clk      (clk),
		.HALTn    (1'b1),          // tied inactive; extReset does the reset
		.extReset (reset),
		.pwrUp    (reset),         // as fx68k's own top level does
		.enPhi1   (en_phi1),
		.enPhi2   (en_phi2),

		.eRWn     (rw),            // 1 = read, 0 = write
		.ASn      (fx_as_n),
		.LDSn     (lds_n),
		.UDSn     (uds_n),
		.E        (fx_e),
		.VMAn     (fx_vma_n),

		.FC0      (fc[0]),
		.FC1      (fc[1]),
		.FC2      (fc[2]),
		.BGn      (fx_bg_n),
		.oRESETn  (fx_reset_n),
		.oHALTEDn (fx_halted_n),

		.DTACKn   (~dtack),
		.VPAn     (vpa_n),
		.BERRn    (1'b1),          // tied high on the board: no bus errors
		.BRn      (1'b1),
		.BGACKn   (1'b1),
		.IPL0n    (ipl_rr[0]),
		.IPL1n    (ipl_rr[1]),
		.IPL2n    (ipl_rr[2]),

		.iEdb     (rdata),
		.oEdb     (wdata),
		.eab      (fx_eab)
	);

endmodule
