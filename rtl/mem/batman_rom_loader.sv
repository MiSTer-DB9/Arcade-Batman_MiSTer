// Adapted for Batman from the Skull & Crossbones core's rtl/mem/skullxbo_rom_loader.sv (GPL-3.0); see NOTICE.md
`timescale 1ns/1ps
//============================================================================
//  Batman ROM download router (MiSTer only): splits the index-0 ioctl stream
//  into its six regions and addresses them in SDRAM and block RAM.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Structure follows the Skull &
//  Crossbones MiSTer core (GPL-3.0, itself from Bad Lands); see NOTICE.md.
//
//    stream base  size      contents                 destination
//    0x000000     0x0C0000  68000 program            SDRAM
//    0x0C0000     0x020000  alpha tiles              SDRAM + block RAM (char_*)
//    0x0E0000     0x100000  playfield tiles          SDRAM, reordered
//    0x1E0000     0x100000  motion objects           SDRAM, reordered
//    0x2E0000     0x010000  JSA 6502 program         SDRAM + block RAM (snd_*)
//    0x2F0000     0x080000  MSM6295 samples          SDRAM
//  Each region's SDRAM byte address is its stream offset.  The 28C16 seed at
//  0x370000 is taken by batman_nvram_io, not here.  In each 16-bit word the
//  even stream byte is D15:8 (the 68000 high byte); the packing is done in
//  batman_sdram_loader.  Outputs are registered.  `rom_loaded` rises when the
//  index-0 download ends; an NVRAM (index 2) load never sets it.
//============================================================================

module batman_rom_loader
(
	input  logic        clk,
	input  logic        reset,          // ~pll_locked only (never the game reset)

	// ---- HPS ioctl download channel ----
	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,     // byte offset into the index-0 stream
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,

	// ---- the SDRAM regions, as one byte stream with its SDRAM address ----
	output logic        sdram_wr,
	output logic [23:0] sdram_addr,     // SDRAM BYTE address

	// ---- alpha tiles -> the alphanumerics ROM in block RAM ----
	output logic        char_wr,
	output logic [16:0] char_addr,      // 0..0x1FFFF, the 128 KB region

	// ---- JSA 6502 program (64 KB ROM at 12C) -> block RAM ----
	output logic        snd_wr,
	output logic [15:0] snd_addr,       // 0..0xFFFF, the 6502's own offset

	// shared byte for every destination (they never strobe in the same cycle)
	output logic  [7:0] rom_data,

	// ---- high once the index-0 download has ended ----
	output logic        rom_loaded
);

	// Region bases in the index-0 stream (size in the comment).
	localparam [26:0] BASE_PROG  = 27'h000000;   // maincpu   0x0C0000
	localparam [26:0] BASE_CHAR  = 27'h0C0000;   // chars     0x020000
	localparam [26:0] BASE_PF    = 27'h0E0000;   // tiles     0x100000
	localparam [26:0] BASE_SPR   = 27'h1E0000;   // sprites   0x100000
	localparam [26:0] BASE_SND   = 27'h2E0000;   // jsa:cpu   0x010000
	localparam [26:0] BASE_OKI   = 27'h2F0000;   // jsa:oki1  0x080000
	localparam [26:0] END_STREAM = 27'h370000;

	wire is_idx0 = (ioctl_index == 16'd0);
	wire wr      = ioctl_download & ioctl_wr & is_idx0;
	wire in_img  = wr && (ioctl_addr < END_STREAM);

	wire in_char = (ioctl_addr >= BASE_CHAR) & (ioctl_addr < BASE_PF);
	wire in_pf   = (ioctl_addr >= BASE_PF)   & (ioctl_addr < BASE_SPR);
	wire in_spr  = (ioctl_addr >= BASE_SPR)  & (ioctl_addr < BASE_SND);
	wire in_gfx  = in_pf | in_spr;

	// =====================================================================
	//  graphics reorder
	// =====================================================================
	// In MAME's order the four bit planes of one stamp row are 0x40000 bytes
	// apart, i.e. in four SDRAM rows.  Each 1 MB region is reordered on the way
	// in so one fetch is one aligned 8-byte group per (code, row pair):
	//      raw   s = plane * 0x40000 + code * 8 + row       (plane 0..3)
	//      SDRAM n = code * 32 + (row >> 1) * 8 + (3 - plane) * 2 + (row & 1)
	// A stamp row (8 pixels, 4 bpp) is then four bytes at stride 2, read by one
	// burst.  Keeping the row pair keeps n[0] == s[0], so consecutive stream
	// bytes still form one SDRAM word.  `3 - plane` puts gfx bit 0 in lane 0.
	// The mapping is a bijection within each region, so region bases do not move.
	wire [19:0] grel = in_pf ? 20'(ioctl_addr - BASE_PF)
	                         : 20'(ioctl_addr - BASE_SPR);
	wire  [1:0] gplane = grel[19:18];
	wire [14:0] gcode  = grel[17:3];
	wire  [2:0] grow   = grel[2:0];
	wire [19:0] gscat  = {gcode, grow[2:1], ~gplane, grow[0]};

	wire [23:0] gbase = in_pf ? 24'(BASE_PF) : 24'(BASE_SPR);
	// 24 bits, not 27: the image ends at byte 0x370000.
	wire [23:0] sdram_byte = in_gfx ? (gbase + {4'd0, gscat}) : 24'(ioctl_addr);

	logic [7:0] data_r;

	always_ff @(posedge clk) begin
		data_r     <= ioctl_dout;
		sdram_wr   <= in_img & ~reset;
		// Alpha tiles and the 6502 program also go to block RAM; their
		// SDRAM copies are written but never read.
		char_wr    <= in_img & ~reset & in_char;
		snd_wr     <= in_img & ~reset
		              & (ioctl_addr >= BASE_SND) & (ioctl_addr < BASE_OKI);
		sdram_addr <= sdram_byte;
		char_addr  <= 17'(ioctl_addr - BASE_CHAR);
		snd_addr   <= 16'(ioctl_addr - BASE_SND);
	end

	assign rom_data = data_r;

	// rom_loaded rises on the falling edge of the index-0 download; `reset`
	// gives it a defined power-up value.
	wire  dl0 = ioctl_download & is_idx0;
	logic dl0_d;
	always_ff @(posedge clk) begin
		if (reset) begin
			dl0_d      <= 1'b0;
			rom_loaded <= 1'b0;
		end else begin
			dl0_d <= dl0;
			if (dl0)        rom_loaded <= 1'b0;   // a download is in progress
			else if (dl0_d) rom_loaded <= 1'b1;   // the first cycle after it ends
		end
	end

	/* verilator lint_off UNUSEDSIGNAL */
	// BASE_PROG is 0, so the program region's address is ioctl_addr itself.
	wire _unused_ldr = &{1'b0, BASE_PROG, ioctl_addr[26:24], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
