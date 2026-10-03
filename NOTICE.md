# NOTICE — third-party components and attributions

This core is distributed under **GPL-3.0-or-later** (see `LICENSE`). It
includes the third-party components below. Each one keeps its original file
headers.

## Components compiled into the core

| Component | Author(s) | Licence | Location |
|---|---|---|---|
| MiSTer framework (`sys_top`, `hps_io`, `arcade_video`, `video_freak`, `ascal`, `osd`, …) | Till Harbaum, Alexey Melnikov (Sorgelig) and the MiSTer-devel contributors | GPL-2.0-or-later / GPL-3.0-or-later (per-file headers) | `sys/`: vendored verbatim, never edited. Template_MiSTer commit `3ea1134` (2026-08-26) |
| **fx68k**, a cycle-exact MC68000 with its microcode ROMs | Jorge Cwik (ijor) | GPL-3.0-or-later | `rtl/lib/fx68k/`: vendored verbatim, with its own `LICENSE` and `README.md` |
| **T65**, a 65xx CPU core (VHDL) | Daniel Wallner, Mike Johnson, Wolfgang Scherr, Morten Leikvoll | BSD-style 3-clause (notice in `T65.vhd`) | `rtl/lib/T65/`: vendored verbatim. `T65_wrap.vhd` is a flat-port wrapper from the Skull & Crossbones core (GPL-3.0) |
| **JT51**, the YM2151 FM synthesiser | José Tejada Gómez (jotego) | GPL-3.0-or-later | `rtl/lib/jt51/`: vendored verbatim |
| **`klax_oki6295.v`**, an MSM6295 ADPCM core | the Klax MiSTer core authors | GPL-2.0-or-later | `rtl/lib/oki/`: vendored verbatim. `rtl/sound/batman_oki.sv` is derived from it |
| `analog_hsize.sv`, the analog-VGA horizontal stretch | Umberto Parisi (rmonic79), from Arcade-Raiden_MiSTer | GPL-3.0-or-later | `rtl/video/analog_hsize.sv`: vendored with the two small changes listed in its header (made by the Toobin' MiSTer core) |
| Intel PLL megafunction (50 MHz → 57.272727 MHz) | Intel Corporation (generated IP) | Intel FPGA IP licence, as generated | `rtl/pll.v`, `rtl/pll/` |

All of these licences are compatible with distributing the combined work
under GPL-3.0-or-later.

## Code adapted from sibling Atari cores

The project structure, build files and a set of board-independent modules
come from the **Skull & Crossbones** MiSTer core (GPL-3.0), which in turn
builds on the Bad Lands, Vindicators, Xybots, Toobin' and Blasteroids cores.
Each adapted file keeps its original copyright header and adds one line naming
the file it came from:

- CPU wrapper, EEPROM and NVRAM: `batman_cpu.sv`, `batman_eeprom_28c16.sv`,
  `batman_nvram_io.sv`
- SDRAM, ROM loading and caches: `batman_sdram.sv`, `batman_sdram_loader.sv`,
  `batman_rom_loader.sv`, `batman_prog_rom.sv`, `batman_gfx_mem.sv`,
  `batman_gfx_client.sv`
- Sound building blocks: `batman_ym.sv`, `batman_oki.sv`,
  `batman_snd_iir1.sv`, `batman_snd_svf.sv`
- Video output: `batman_analog_adjust.sv`
- The motion-object engine `batman_mob.sv` starts from the Skull & Crossbones
  transcription of the same Atari custom chip, MOB 137593-001, reconfigured
  for this board.

Everything else under `rtl/` (address decoding, the GAL equations, the
VAD video chip, playfields, alphanumerics, line buffers, mixer, colour RAM and
DACs, and the JSA III sound board) was written for Batman from the Atari
schematics and the GAL fuse maps. A few modules borrow only their file layout
from Skull & Crossbones.

## Reference material

MAME (BSD-3-Clause; Aaron Giles and the MAME contributors) served as a
functional reference and for comparison captures. No MAME source is compiled
into this core.

## Trademarks and content

This repository contains no ROM data, no artwork, no schematics and no PLD
fuse dumps. *Batman* and all related characters and elements are trademarks
of their respective owners. This is an unaffiliated hardware-preservation
project. Use it only with ROMs you are legally entitled to.
