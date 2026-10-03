`timescale 1ns/1ps
//============================================================================
//  Batman (Atari Games, 1990/91) - JSA III audio board A048974-01: the 4 ms
//  interrupt timer (two LS393 at 19A/20A, both halves of the LS74 at 18B) and
//  the wired-AND /IRQ line of the 6502.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.  See LICENSE, NOTICE.md.
//
//  Counter shape from the Skull & Crossbones core's skullxbo_snd_bus.sv
//  (GPL-3.0); the divider chain, counts and /IRQ merge are this board's.
//
//  3579K /4 /16 /16 (19A, 20A-B; clears tied to GND, free-running) gives
//  3495.65 Hz into 20A-A.  18B/1 and 18B/2 decode count 14 of 20A-A, so 4MSIRQ
//  rises every 14 ticks = 4.005 ms = exactly 7168 cycles of the 6502 clock.
//
//  The timer is acknowledge-gated: 4MSIRQ holds 20A-A cleared until the 6502
//  strobes /IRQACK, so the next interrupt comes 4.005 ms after the ack, not
//  after the previous interrupt.  MAME uses a free-running periodic timer;
//  MAME_FREERUN = 1 reproduces that for comparison.  /IRQACK is 18B/2's
//  asynchronous /CLR, fires on a read or a write of $2806, and wins over a
//  coincident divider edge.
//
//  /IRQ = !(4MSIRQ | YM2151 IRQ): GAL 20C pin 18 and the YM2151's open-drain
//  output share the line.  /IRQACK does not clear the YM2151's IRQ.
//  18B has no reset input on the board; por is only the FPGA power-up value.
//============================================================================

module batman_snd_irq #(
	// 3579K /4 /16 /16: the three free-running stages.
	parameter int IRQ_PRE      = 1024,
	// 20A-A + 18B: the /14 stage that stops while the interrupt is pending.
	parameter int IRQ_POST     = 14,
	// Test only.  1 = MAME's free-running divider instead of the board's
	// ack-gated one.
	parameter bit MAME_FREERUN = 1'b0
) (
	input  logic        clk,
	input  logic        ce_3m58,      // 3579K -- the LS393 chain's input
	input  logic        por,          // the FPGA power-up value (not /RESET)

	input  logic        sel_irqack,   // /IRQACK ($2806), read or write
	input  logic        ym_irq,       // YM2151 9C1 pin 2, asserted (1)
	input  logic        irq_gal_lo,   // GAL 20C pin 18 is pulling the node down

	output logic        ms4irq,       // 18B/2 Q -> 20A-A CLR and 20C pin 1
	output logic        irq_n,        // 6502 11C pin 4
	output logic        dbg_pre_tick  // one clk per 3495.65 Hz edge (debug)
);

	localparam int PREW  = $clog2(IRQ_PRE);
	localparam int POSTW = $clog2(IRQ_POST);

	logic [PREW-1:0]  pre_cnt;
	logic [POSTW-1:0] post_cnt;

	// 19A-A / 19A-B / 20A-B: CLR at GND, so nothing ever stops these.
	wire pre_tick = ce_3m58 & (pre_cnt == PREW'(IRQ_PRE-1));
	assign dbg_pre_tick = pre_tick;

	always_ff @(posedge clk) begin
		if (por) begin
			pre_cnt <= '0; post_cnt <= '0; ms4irq <= 1'b0;
		end else begin
			if (ce_3m58) begin
				pre_cnt <= pre_cnt + PREW'(1);
				if (pre_cnt == PREW'(IRQ_PRE-1)) begin
					if (post_cnt == POSTW'(IRQ_POST-1)) begin
						post_cnt <= '0;
						ms4irq   <= 1'b1;   // 18B/2 sets at count 14
					end else begin
						post_cnt <= post_cnt + POSTW'(1);
					end
				end
			end
			// 18B/2's Q holds 20A-A's active-high CLR while the interrupt
			// is pending, so the /14 stage cannot advance.
			if (!MAME_FREERUN && ms4irq) post_cnt <= '0;
			// /IRQACK is 18B/2's asynchronous /CLR: it wins over a
			// coincident divider edge, so it is applied last.
			if (sel_irqack) ms4irq <= 1'b0;
		end
	end

	// The wired-AND.  irq_gal_lo (GAL 20C pin 18) equals ms4irq, but is taken
	// from the single GAL model in batman_snd_decode rather than re-derived.
	assign irq_n = ~( irq_gal_lo | ym_irq );

endmodule
