// Adapted for Batman from the Skull & Crossbones core's rtl/main/skullxbo_nvram_io.sv (GPL-3.0); see NOTICE.md
`timescale 1ns/1ps
//============================================================================
//  MiSTer load/save controller for the Batman 28C16 EEPROM at 12R.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Ported from the Badlands MiSTer
//  core (GPL-3.0, same author; itself from Blasteroids / Xybots / Toobin').
//
//  The board has no DIP switches: every game and coin option lives in the
//  EEPROM.  Two load paths: ioctl index 2 is the .nvm restore/save channel;
//  index 0 (the ROM stream) carries batman-eeprom.bin at 0x370000 as a factory
//  seed (seed_we).  The seed window is decoded on the full address so no
//  program-ROM byte can reach the EEPROM.  After a write, the module waits
//  SETTLE_CYCLES of quiet and then requests one upload, so a burst of option
//  writes gives a single save.  The dirty flag survives board and watchdog
//  resets, as the physical EEPROM contents do.
//============================================================================

module batman_nvram_io #(
	// ~1.17 s at 57.272727 MHz: long enough that a burst of option writes from
	// one self-test page produces a single upload.
	parameter int unsigned SETTLE_CYCLES = 67_108_863
)(
	input  logic        clk,
	input  logic        init_reset,

	input  logic        write_accepted,   // from batman_eeprom_28c16

	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,
	input  logic        ioctl_upload,

	output logic        load_we,
	output logic [10:0] load_addr,
	output logic  [7:0] load_data,
	output logic        seed_we,          // this load byte is the index-0 factory seed
	output logic        load_end,         // 1-clk: an index-2 download just ended
	output logic [10:0] dump_addr,
	input  logic  [7:0] dump_data,

	output logic        ioctl_upload_req,
	output logic  [7:0] ioctl_upload_index,
	output logic  [7:0] ioctl_din
);

	// Index 2 only; a longer file than 2 KB simply wraps.
	wire index2_nvram = (ioctl_index == 16'd2);

	// Index-0 stream 0x370000-0x3707FF is batman-eeprom.bin from the MRA; the
	// window is 2 KB aligned, so ioctl_addr[10:0] is the cell for both sources.
	localparam [26:0] SEED_BASE = 27'h370000;
	localparam [26:0] SEED_END  = 27'h370800;
	wire index0_seed = (ioctl_index == 16'd0)
	                 & (ioctl_addr >= SEED_BASE) & (ioctl_addr < SEED_END);

	assign seed_we   = ioctl_download & ioctl_wr & index0_seed;
	assign load_we   = (ioctl_download & ioctl_wr & index2_nvram) | seed_we;
	assign load_addr = ioctl_addr[10:0];

	// end of an index-2 download: an all-zero image then replays the seed
	logic dl2_d;
	wire  dl2 = ioctl_download & index2_nvram;
	always_ff @(posedge clk) begin
		if (init_reset) dl2_d <= 1'b0;
		else            dl2_d <= dl2;
	end
	assign load_end = dl2_d & ~dl2;
	assign load_data = ioctl_dout;
	assign dump_addr = ioctl_addr[10:0];

	localparam int SETTLE_W = (SETTLE_CYCLES <= 1) ? 1 : $clog2(SETTLE_CYCLES + 1);
	logic [SETTLE_W-1:0] settle;
	logic dirty;
	wire  settled      = (settle == SETTLE_W'(SETTLE_CYCLES));
	wire  upload_start = ioctl_upload & index2_nvram;

	always_ff @(posedge clk) begin
		if (init_reset) begin
			dirty  <= 1'b0;
			settle <= '0;
		end else if (write_accepted) begin
			dirty  <= 1'b1;      // a new byte cannot be cleaned by a concurrent upload
			settle <= '0;
		end else if (load_we || upload_start) begin
			dirty  <= 1'b0;
			settle <= '0;
		end else if (dirty && !settled) begin
			settle <= settle + 1'b1;
		end
	end

	assign ioctl_upload_req   = dirty & settled;
	assign ioctl_upload_index = 8'd2;
	assign ioctl_din          = dump_data;


endmodule
