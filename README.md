# Batman for MiSTer FPGA

An FPGA recreation of Atari Games' **Batman** (1991) arcade hardware. It
covers the game PCB **A048987-01**, a 68000 board with Atari's VAD and MOB
video customs, and the **JSA III** sound board **A048974-01**, which has a
6502, a YM2151 and an OKI MSM6295.

This core recreates the hardware; it is not a re-implementation of the game.
The address decoding, the sound board and the video mixer come from Atari's
schematics and from the dumped GAL chips. MAME is used as a cross-reference
for what the schematics do not cover. Where the schematics and MAME disagree,
the core follows the schematics, so a few things deliberately differ from
MAME. They are listed below.

<img src="https://img.shields.io/badge/Quartus-17.0.2-blue" alt="Quartus 17.0.2"> <img src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue" alt="GPL-3.0-or-later">

---

## Supported games

| MRA | Set |
|-----|-----|
| `Batman.mra` | `batman` |

MAME has one Batman set, with no clones.

Batman has **no DIP switches**. Coinage, difficulty, lives, the extra-life
score and attract-mode sound are stored in the on-board EEPROM, together with
the high scores. You change them in the game's own service menu (see
*Service* below).

---

## Installing

1. Copy `releases/Batman_<date>.rbf` to `/media/fat/_Arcade/cores/`.
2. Copy `releases/Batman.mra` to `/media/fat/_Arcade/`.
3. Put the MAME ROM set `batman.zip` in `/media/fat/games/mame/`.

**This repository contains no ROM data.** The MRA refers to the ROM parts by
name and CRC only. It also carries an `md5` over the whole ROM set. If your
zip does not match, MiSTer does not load the ROMs at all, so a core that
starts and then shows nothing almost always means the wrong `batman.zip`.

**Settings and high scores** are kept in the EEPROM image, which MiSTer saves
as a 2 KB file in its saves folder. After the game writes to the EEPROM, the
core asks MiSTer to save it. MiSTer writes the file the next time the OSD is
opened.

**First boot.** Before a save file exists, the core fills the EEPROM from the
factory image in the MAME set (`batman-eeprom.bin`). The game therefore starts
with its default settings and a normal volume. From then on, your own save
file is used.

**Volume.** The game has its own master volume, set in the service menu under
**Adjust Volume** and saved with the other settings. If the game is quiet or
silent, raise it there. The sound board's volume knob only feeds its speaker
amplifier, which the core leaves out: use MiSTer's volume control instead.

---

## Controls

Batman is a one-player game: an 8-way joystick and two buttons.

| Function | Default pad button | Notes |
|----------|--------------------|-------|
| Move | D-pad / stick | 8-way |
| Fire | A | The game's self test calls it START/FIRE |
| Jump | B | |
| Start | Start | The board's START 1 input |
| Coin | Select | Coins are read by the sound board, as on the real cabinet. Pad 2's Select is the second coin slot |

The board also wires a full second-player control set, which the game never
reads; the core connects it to pad 2 anyway. The board's third button, its
service-credit button and its tilt switch are not needed for play, so the
core leaves them released.

### OSD options

| Option | Effect |
|--------|--------|
| Aspect ratio / Orientation / Scale | Standard MiSTer video options |
| CRT Adjust | On/Off, then CRT H-Size, CRT H-Position and CRT V-Shift, for CRT and analog VGA output. The three amounts appear only while CRT Adjust is On, and it stays off while the scandoubler is forced on |
| Service | The cabinet's self-test switch. Turn it **On** to enter the service menu and **Off** to leave |
| Reset | Resets the board |

CRT Adjust is Off by default, and Off leaves the video output exactly as the
core produces it. When it is On the picture goes through a one-line buffer, so
HDMI follows the adjustment too; leave it Off for an untouched HDMI picture.
H-Position moves the picture, never the sync. On this raster the right-hand
margin is short: at H-Size 0, H-Position beyond +39 cuts the right edge, and
enlarging H-Size past +5 needs a negative H-Position to keep the right edge.

---

## Hardware overview

| | |
|---|---|
| Main CPU | MC68000 (fx68k), 768 KB program ROM, 64 KB work RAM, 2 KB 28C16 EEPROM |
| Video | Atari VAD and MOB 137593-001: two 64 × 64 playfields of 8 × 8 tiles (16 colours), a 64 × 30 text layer, motion objects (sprites), two line buffers, 2048-entry colour RAM |
| Sound | JSA III: 6502 (T65), YM2151 + YM3012 (jt51), OKI MSM6295, and the board's analog filters |
| Video timing | 456 × 262 total, **336 × 240 visible**, 7.159 MHz pixel clock, 59.92 Hz, 15 kHz horizontal |
| Clocking | One 57.272727 MHz system clock (4 × the board's 14.318181 MHz crystal). Every chip clock is an integer division of it |

---

## Accuracy notes

- **Address decoding from the actual chips.** The 68000's memory map is the
  dumped GAL 136085-1002 at 9L, together with the 74-series decoders drawn on
  the schematics. The GAL equations are transcribed from the fuse map, and
  a test compared every address against a model built from the fuse file
  itself.
- **Bus timing.** Wait states come from the board's F163 counter, and
  interrupts use the schematic's priority encoding: level 4 for the video
  scanline interrupt, level 6 for the sound board. The watchdog and the
  EEPROM write-unlock latch are modelled as drawn.
- **The whole JSA III sound board.** Its two GALs (136085-1038 and -1039)
  come from their fuse maps. The 6502's 4 ms interrupt timer only restarts
  after the 6502 acknowledges it, as on the board; MAME runs it freely. The
  6502 is held in reset until the 68000 releases it.
- **Analog audio.** The board's filter and mixer stages are modelled from the
  component values on the schematics, which were cross-checked against
  Atari's parts lists for the same board design. MAME applies no filtering,
  so this core sounds darker than MAME, as the real board does. The ADPCM and
  FM chips are mixed 33 : 15, as the mixer resistors set it; MAME uses 0.75 :
  0.60. The board's ADPCM gain switch also moves a filter pole, so its level
  step rises from ×2.43 at low frequencies to ×3.0 above 2 kHz. MAME uses a
  flat ×2.
- **ADPCM ROM banking from the GAL.** In one bank, the GAL on the sound board
  selects a different sample ROM than MAME's hard-coded mapping. The two
  mappings differ on 39.5 % of that bank's samples.
- **Video mixing and colour.** The four priority GALs (136085-1003, -1004,
  -1005 and -1006) come from their fuse maps. The colour DACs follow the
  resistor ladder on the schematic, including the black-level clamp, which
  MAME does not model.
- **Line buffers** follow the Atari custom chips: when two sprites overlap,
  the first one written wins, and each pixel is erased right after it is
  displayed.

### Known deviations and open questions

- **The video schematics are missing.** The kit manual leaves out
  the pages for the VAD, the MOB, the video RAM, the graphics ROMs and the
  line buffers. That part of the core follows MAME's behaviour, the fuse maps
  of the GALs around it and sibling Atari cores, and it was checked
  frame by frame against MAME and on real hardware.
- **68000 clock.** The board can run the CPU at 14.318 MHz or 7.159 MHz,
  chosen by a solder jumper hidden under the sound board. The core uses
  14.318 MHz, as MAME does. A photo of the jumper pads on a real board would
  settle it.
- **FM : ADPCM balance.** The filter shapes come from the schematic, but the
  overall level ratio between the two sound chips depends on their output
  levels, which no schematic gives. It is set by one pair of constants,
  `BAL_OKI` and `BAL_YM` in `rtl/sound/batman_snd_mix.sv`.
- **Motion-object configuration.** The game writes three configuration words
  to the MOB whose meaning is not documented anywhere. The core stores them
  but does not interpret them, and every captured frame still matches.

---

## Verification

The core was developed simulation-first, with AI assistance, under human
review and hardware testing. Each subsystem was checked against an
independent reference:

| Subsystem | Method | Result |
|-----------|--------|--------|
| Main-board decode | All 2,097,152 word addresses in three bus states, against a model parsed from the GAL fuse file | Exact |
| Sound-board decode | Both GALs over their full input space, and the assembled decoder over 1,048,576 vectors | Exact |
| Video mixer GALs | Exhaustive, against expectations parsed from the fuse dumps | Exact |
| Boot | 338,939 bus cycles of the 68000 from power-on (every write, and every access outside the program ROM), compared one by one with MAME | Same cycles in the same order. The only differences are four status reads made while the sound CPU is still held in reset (it starts later on the real board than in MAME), and the first interrupt, after which the core and MAME no longer run in step |
| Video | 44 frames (attract, gameplay, the staircase scene, all four self-test screens, synthetic states) compared pixel by pixel with MAME, with graphics fetched through the real SDRAM path | 3,548,160 pixels, 0 mismatches |
| Sound | 3 s of attract and 22 s of gameplay replayed against MAME recordings | Every sound-chip write made in answer to a game command matches MAME in order and value |
| Whole core | Built with Quartus 17.0.2 and run on DE10-Nano boards by the author and by other testers | Boots and plays with no problems reported. Screenshots of the four self-test screens taken on MiSTer match MAME pixel for pixel, apart from the black-level clamp |

The test benches, MAME captures and development notes behind these results
are not part of this repository.

Resource use of the shipped build (Cyclone V 5CSEBA6U23I7): 14,120 / 41,910
ALMs (34 %), 457 / 553 M10K blocks (83 %), 67 / 112 DSP blocks. Timing is met
on every corner, with +1.9 ns of setup slack on the system clock.

---

## Building

Quartus Prime **17.0.2** (Lite or Standard), as for other MiSTer cores.

1. Open `Batman.qpf`.
2. Compile. The output is `output_files/Batman.rbf`.
3. For a release, copy it to `releases/Batman_YYYYMMDD.rbf`.

Or from the command line:

```bash
quartus_sh --flow compile Batman
```

Sources are listed in `files.qip`. Add new files there by hand, not through
the Quartus IDE, which writes them into `Batman.qsf` instead. `Batman.qsf`
pins fitter seed 3. Re-check timing if you change it.

---

## Repository layout

```text
Batman.qpf / .qsf / .sdc    Quartus project
Arcade-Batman.sv            Glue between the MiSTer framework and the core
files.qip                   Source file list
rtl/
  batman_core.sv            Game top level: both boards
  batman_clocks.sv          Clock enables, all divided from the one system clock
  main/                     68000 board: CPU, decode, wait states, IRQs, EEPROM, inputs
  video/                    VAD, playfields, text layer, motion objects, line buffers, mixer, DACs
  sound/                    JSA III: 6502, decode GALs, mailbox, YM2151, MSM6295, analog mix
  mem/                      SDRAM controller, ROM loader and caches
  lib/                      Third-party cores: fx68k, T65, jt51, OKI
  pll.v, pll/               PLL megafunction
sys/                        MiSTer framework, unmodified
releases/                   RBF and MRA
clean.bat                   Deletes Quartus build output
```

**Reading the source.** Comments name chips by their position on the Atari
board, such as "GAL at 9L" or "LS273 at 1S", and the GAL modules name their
ports by pin number. Schematic page numbers are page numbers in the 55-page
PDF scan of Atari's Batman kit manual (TM-364): the game board is on pages
40-45 and the JSA III sound board on pages 46-51. The manual is not included
here.

---

## Licensing

The core is **GPL-3.0-or-later** (see `LICENSE`). `NOTICE.md` lists every
third-party component and its licence:

| Component | Licence |
|-----------|---------|
| `rtl/` (this core), `Arcade-Batman.sv` | GPL-3.0-or-later |
| `rtl/lib/fx68k/`, © Jorge Cwik | GPL-3.0-or-later |
| `rtl/lib/T65/`, © Daniel Wallner and contributors | BSD-style |
| `rtl/lib/jt51/`, © José Tejada Gómez | GPL-3.0-or-later |
| `rtl/lib/oki/`, from the Klax MiSTer core | GPL-2.0-or-later |
| `rtl/video/crt_adjust.sv`, © Umberto Parisi (rmonic79) | GPL-3.0-or-later |
| `sys/`, MiSTer framework, © Alexey Melnikov and contributors | GPL-2.0-or-later / GPL-3.0-or-later |

---

## Credits

- **Atari Games**: the original hardware and game.
- **Jorge Cwik (ijor)**: the fx68k 68000 core.
- **Daniel Wallner, MikeJ and contributors**: the T65 6502 core.
- **José Tejada Gómez (jotego)**: the jt51 YM2151 core.
- **Umberto Parisi (rmonic79)**: `crt_adjust.sv`, from
  [MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust)
  (commit `c682de9`).
- **The Atari MiSTer cores**: Skull & Crossbones, Bad Lands, Vindicators,
  Xybots, Toobin', Klax and Blasteroids. They supplied the project structure,
  the SDRAM and ROM-loading chain, the OKI core and the MOB 137593-001
  transcription this core builds on.
- **Alexey Melnikov (Sorgelig)** and the MiSTer-devel community: the MiSTer
  framework.
- **The MAME team**: `batman.cpp`, `atarivad`, `atarimo` and `atarijsa` (Aaron
  Giles and contributors) were the cross-reference for everything the
  schematics do not cover.

*Batman* and all related characters and elements are trademarks of their
respective owners. This project is not affiliated with or endorsed by them.
