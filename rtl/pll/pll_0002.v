`timescale 1ns/10ps
//============================================================================
//  Vindicators core PLL — Altera PLL (Cyclone V fPLL), hand-parameterised.
//
//  Adapted from the Toobin' core's rtl/pll/pll_0002.v (same megafunction
//  instantiation, different counters) rather than re-running the MegaWizard, so
//  the parameters are reviewable in the diff.
//
//  refclk = CLK_50M (FPGA_CLK1_50, 50.000000 MHz)
//
//  outclk_0 = clk_sys  = 57.272727 MHz = 50 x 63 / 5 / 11
//      M = 63, N = 5  -> VCO = 630.000 MHz  (Cyclone V fPLL VCO range is
//      600..1600 MHz, so 630 MHz is legal on the -7 speed grade this board
//      uses; the megafunction picks these counters from the requested output
//      frequency, and the fitter's PLL Summary in output_files/Vindicators.fit.rpt
//      is the check that it did).
//      C = 11 -> 630 / 11 = 57.272727... MHz.
//      Target is 4 x the SP-313 sheet-4 crystal, 4 x 14.318181 = 57.272724 MHz;
//      the error is +3.3 Hz = 0.06 ppm, i.e. exact for every practical purpose.
//      Every game rate is an integer division of this (docs/PLAN.md 3.1):
//        /4 = 14.318181 MHz (SYNGEN)   /8 = 7.159091 MHz (VIDCLK + 68000)
//        /16 = 3.579545 MHz (YM2151)   /32 = 1.789772 MHz (JSA 6502)
//
//  outclk_1 = clk_sdram = the SAME 57.272727 MHz, phase-shifted, destined for
//      the SDRAM_CLK pin.  Toobin' drives its SDRAM_CLK from a -112.5 deg tap
//      whose value was found by an eight-point HARDWARE sweep at 64 MHz (STA
//      predicted the wrong answer every time it was consulted; see Toobin's
//      Arcade-Toobin.sdc header and tests/build_phase_sweep.sh).
//
//      THAT ANGLE DOES NOT TRANSFER.  The read-capture window is set by the
//      board's round-trip delay in PICOSECONDS, not in degrees, so at a
//      different clock period the same delay is a different angle.  What is
//      carried over is therefore the *delay*:
//          64.000000 MHz: period 15625.0 ps, -112.5 deg = -4883 ps
//          57.272727 MHz: period 17460.3 ps
//      A negative shift is expressed as its positive equivalent (they are the
//      same edge on a periodic clock):  17460.3 - 4883 = 12577 ps.
//      The Cyclone V fPLL quantises the shift to VCO/8 = 198.41 ps steps (88
//      taps over this period, = 8 x C = 8 x 11 — which is itself a check that
//      the megafunction really did pick C = 11); Quartus REJECTS anything else
//      with "PLL Output Counter parameter 'phase_shift' is set to an illegal
//      value", and it also rejects negative values here.  The legal tap nearest
//      12577 ps is 12500 ps (tap 63) = -4960 ps = -102.3 deg, used below.
//
//      12500 ps IS AN INITIAL GUESS ONLY.  It MUST be re-swept on real hardware
//      before the SDRAM read path is trusted (M4/M8 hardware gate).  Nothing in
//      the M2 template depends on it: the chip is held deselected with CKE low.
//============================================================================
module  pll_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// interface 'outclk0'  -- clk_sys, 57.272727 MHz
	output wire outclk_0,

	// interface 'outclk1'  -- SDRAM_CLK, 57.272727 MHz, +13095 ps = tap 66 = 270 deg (HARDWARE-SWEPT 2026-09-04: good window 225-315 deg, centre chosen)
	output wire outclk_1,

	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(2),
		.output_clock_frequency0("57.272727 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("57.272727 MHz"),
		.phase_shift1("13095 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("0 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		.outclk	({outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule
