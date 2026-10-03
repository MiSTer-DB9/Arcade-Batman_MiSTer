`timescale 1ns/1ps
//============================================================================
//  Batman /DTACK: the 74F163 wait counter at 8K and the LS04 at 12M that
//  inverts its RCO into the 68000's /DTACK (from the schematic, page 44).
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.  Structure follows the Skull &
//  Crossbones MiSTer core (GPL-3.0); see NOTICE.md.
//
//  Wiring: CK = CPUCLK, /CLR = BAS (synchronous), /LOAD = QC, ENP = /DTACK,
//  ENT = +5V, D..A = /VPA, /VRWAIT, /WAIT2, /WAIT.  The counter is cleared
//  between cycles, loads P at S4, and asserts /DTACK when it reaches 15.
//  Each asserted (low) wait line removes one from P, adding one CPU clock:
//     0x0xxxxx ROM          P = 14   1 wait state
//     0x1xxxxx              P = 13   2 wait states
//     0x2xxxxx-0x3DFFFF     P = 15   no wait states
//     0x3Exxxx-0x3Fxxxx     P = 10   frozen (QC = 0 reloads) until /VDTACK,
//                                    then /DTACK two CPU clocks later
//     interrupt acknowledge P = 2    frozen: /DTACK never asserts (autovector)
//  Wait states come from the GAL fuse map; MAME models none.
//============================================================================

module batman_dtack #(
	// 1 = count on ce_14m, 0 = on ce_7m.  Must match batman_cpu (same clock node).
	parameter bit CPU_14M = 1'b1
)(
	input  logic       clk,       // clk_sys 57.272727 MHz
	input  logic       ce_14m,    // clk_sys/4
	input  logic       ce_7m,     // clk_sys/8

	input  logic       bas,       // ACTIVE HIGH copy of /AS, pin 1 (/CLR)
	input  logic       wait_n,    // 9L pin 13 -> pin 3 (A)
	input  logic       wait2_n,   // 9L pin 12 -> pin 4 (B)
	input  logic       vrwait_n,  // 9L pin 15 -> pin 5 (C)
	input  logic       vpa_n,     // 7D LS20 pin 6 -> pin 6 (D)

	output logic       dtack,     // ACTIVE HIGH (= the RCO net, ~/DTACK)
	output logic       ce_cpu,    // the CPUCLK rising tick this counter used
	output logic [3:0] count      // QD..QA, for observation
);

	// ---------------- CPUCLK ----------------------------------------------
	assign ce_cpu = CPU_14M ? ce_14m : ce_7m;

	// ---------------- 74F163 8K -------------------------------------------
	logic [3:0] q;
	assign count = q;

	// D,C,B,A = /VPA, /VRWAIT, /WAIT2, /WAIT
	wire [3:0] load_val = {vpa_n, vrwait_n, wait2_n, wait_n};

	wire ent    = 1'b1;                 // pin 10 = +5V
	wire rco    = (q == 4'hF) & ent;    // pin 15
	wire load_n = q[2];                 // pin 9 /LOAD = QC (pin 12)
	wire enp    = ~rco;                 // pin 7 = the /DTACK net

	assign dtack = rco;                 // RCO -> 12M LS04 -> /DTACK

	always_ff @(posedge clk) begin
		if (ce_cpu) begin
			// A '163's synchronous CLEAR dominates its synchronous LOAD, and
			// LOAD ignores both enables.
			if (!bas)           q <= 4'd0;        // /CLR = BAS
			else if (!load_n)   q <= load_val;    // /LOAD = QC
			else if (enp & ent) q <= q + 4'd1;
			// else hold: ENP low means /DTACK is already out
		end
	end

endmodule
