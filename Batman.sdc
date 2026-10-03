derive_pll_clocks
derive_clock_uncertainty

# ============================================================================
#  Batman core timing constraints.
#
#  Structure follows SkullXBones.sdc of the Skull & Crossbones MiSTer
#  core (GPL-3.0); see NOTICE.md.
#
#  One fabric clock drives the game logic:
#     clk_sys = 57.272727 MHz (PLL outclk_0, 50 MHz x 63 / 5 / 11)
#             = 4 x the board's 14.318181 MHz crystal, period 17.461 ns.
#  Everything else runs on integer clock enables (rtl/batman_clocks.sv):
#     ce_14m  = clk_sys / 4   14.318181 MHz  (VAD; 68000 at full speed)
#     ce_7m   = clk_sys / 8    7.159091 MHz  (pixel; 68000 at half speed)
#     ce_3m58 = clk_sys / 16   3.579545 MHz  (YM2151)
#     ce_1m79 = clk_sys / 32   1.789772 MHz  (6502)
#     ce_1m19 = clk_sys / 48   1.193182 MHz  (MSM6295)
#
#  Multicycle exceptions apply only to the vendored clock-enabled cores (fx68k's
#  documented paths, T65, jt51).  Full-rate logic (SDRAM, arbiter, video, bus
#  decode) gets none.  An exception whose hierarchy does not match is skipped
#  silently, so each block checks its registers exist and reports either way
#  in the timing log.  The instance names used here must not change.
# ============================================================================

# ============================================================================
#  MAIN CPU - fx68k at 6L/M (rtl/lib/fx68k, instance u_core|u_main|u_cpu|u_fx68k)
#  Jorge Cwik's own constraints from fx68k.txt "Timing analysis": Ir,
#  microAddr and nanoAddr change only on enT1, at least 8 clk_sys apart
#  (16 with the 68000 on ce_7m), so the opcode PLA gets two cycles.  The
#  uRom / nanoRom output registers have no enable and get no exception.
# ============================================================================
set fx68k_ir [get_registers -nowarn {*u_main|u_cpu|u_fx68k|Ir[*]}]
if {[get_collection_size $fx68k_ir] > 0} {
	post_message -type info "Batman SDC: fx68k main CPU present -- applying fx68k.txt microcode multicycle exceptions"
	set_multicycle_path -start -setup -from [get_registers {*u_main|u_cpu|u_fx68k|Ir[*]}] -to [get_registers {*u_main|u_cpu|u_fx68k|microAddr[*]}] 2
	set_multicycle_path -start -hold  -from [get_registers {*u_main|u_cpu|u_fx68k|Ir[*]}] -to [get_registers {*u_main|u_cpu|u_fx68k|microAddr[*]}] 1
	set_multicycle_path -start -setup -from [get_registers {*u_main|u_cpu|u_fx68k|Ir[*]}] -to [get_registers {*u_main|u_cpu|u_fx68k|nanoAddr[*]}] 2
	set_multicycle_path -start -hold  -from [get_registers {*u_main|u_cpu|u_fx68k|Ir[*]}] -to [get_registers {*u_main|u_cpu|u_fx68k|nanoAddr[*]}] 1
} else {
	post_message -type info "Batman SDC: fx68k main CPU not in this build -- its multicycle exceptions skipped"
}

# ============================================================================
#  SOUND 6502 - T65 at 11C (rtl/lib/T65, instance u_core|u_sound|u_cpu|u_t65)
#  Every register in T65.vhd is gated by one Enable, driven from ce_1m79 =
#  clk_sys/32.  Eight cycles is conservative against 32.
# ============================================================================
set t65_regs [get_registers -nowarn {*u_sound|u_cpu|u_t65|*}]
if {[get_collection_size $t65_regs] > 0} {
	post_message -type info "Batman SDC: T65 sound 6502 present -- applying the ce_1m79 intra-core multicycle exception"
	set_multicycle_path -setup -end 8 -from [get_registers {*u_sound|u_cpu|u_t65|*}] -to [get_registers {*u_sound|u_cpu|u_t65|*}]
	set_multicycle_path -hold  -end 7 -from [get_registers {*u_sound|u_cpu|u_t65|*}] -to [get_registers {*u_sound|u_cpu|u_t65|*}]
} else {
	post_message -type info "Batman SDC: T65 sound 6502 not in this build -- its multicycle exception skipped"
}

# ============================================================================
#  YM2151 - jt51 (instance u_core|u_sound|u_ym|u_jt51)
#  The LFO PM value, the channel registers and the operator register file
#  change only on cen_p1 (ce_1m79, 32 clk_sys apart) and feed keycode_II.
# ============================================================================
set jt51_kc [get_registers -nowarn {*u_sound|u_ym|u_jt51|u_pg|keycode_II[*]}]
if {[get_collection_size $jt51_kc] > 0} {
	post_message -type info "Batman SDC: jt51 YM2151 present -- applying the cen_p1 keycode multicycle exceptions"

	set_multicycle_path -setup -end 2 \
	  -from [get_registers {*u_sound|u_ym|u_jt51|u_lfo|pm[*]}] \
	  -to   [get_registers {*u_sound|u_ym|u_jt51|u_pg|keycode_II[*]}]
	set_multicycle_path -hold -end 1 \
	  -from [get_registers {*u_sound|u_ym|u_jt51|u_lfo|pm[*]}] \
	  -to   [get_registers {*u_sound|u_ym|u_jt51|u_pg|keycode_II[*]}]

	set_multicycle_path -setup -end 2 \
	  -from [get_registers {*u_sound|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kc[*]* *u_sound|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kf[*]* *u_sound|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|pms[*]*}] \
	  -to   [get_registers {*u_sound|u_ym|u_jt51|u_pg|keycode_II[*]}]
	set_multicycle_path -hold -end 1 \
	  -from [get_registers {*u_sound|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kc[*]* *u_sound|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kf[*]* *u_sound|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|pms[*]*}] \
	  -to   [get_registers {*u_sound|u_ym|u_jt51|u_pg|keycode_II[*]}]

	set_multicycle_path -setup -end 2 \
	  -from [get_registers {*u_sound|u_ym|u_jt51|u_mmr|u_reg|u_csr_op|u_reg1op|*}] \
	  -to   [get_registers {*u_sound|u_ym|u_jt51|u_pg|keycode_II[*]}]
	set_multicycle_path -hold -end 1 \
	  -from [get_registers {*u_sound|u_ym|u_jt51|u_mmr|u_reg|u_csr_op|u_reg1op|*}] \
	  -to   [get_registers {*u_sound|u_ym|u_jt51|u_pg|keycode_II[*]}]
} else {
	post_message -type info "Batman SDC: jt51 YM2151 not in this build -- its multicycle exceptions skipped"
}

# ============================================================================
#  SDRAM external I/O timing (MT48LC16M16 class, CL2, 57.272727 MHz controller).
#
#  SDRAM_CLK is PLL outclk_1 (the second output counter, general[1]) wired
#  straight to the pin in Arcade-Batman.sv.  Data-sheet values below.  The
#  read-capture phase in rtl/pll/pll_0002.v is inherited from the sibling
#  Atari MiSTer cores.
# ============================================================================
create_generated_clock -name SDRAM_CLK \
  -source [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {SDRAM_CLK}]

# Read capture: data access time tAC = 6.0 ns (max), output hold tOH = 2.5 ns (min).
set_input_delay  -clock SDRAM_CLK -max 6.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock SDRAM_CLK -min 2.5 [get_ports {SDRAM_DQ[*]}]

# Command/address/data launch: input setup tIS = 1.5 ns (max), hold tIH = 0.8 ns (min).
set_output_delay -clock SDRAM_CLK -max  1.5 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock SDRAM_CLK -min -0.8 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]

# The controller launches and captures on clk_sys (outclk_0); SDRAM_CLK is
# phase-shifted from it, so allow the read the proper (next) capture edge
# instead of the half-cycle one.  get_clocks does Tcl string matching where
# [..] is a character class, so "general[0]" is matched with "?" wildcards.
set_multicycle_path -setup -end 2 \
  -from [get_clocks {SDRAM_CLK}] \
  -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general?0?.gpll~PLL_OUTPUT_COUNTER|divclk}]
set_multicycle_path -hold -end 1 \
  -from [get_clocks {SDRAM_CLK}] \
  -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general?0?.gpll~PLL_OUTPUT_COUNTER|divclk}]
