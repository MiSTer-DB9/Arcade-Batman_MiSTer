//============================================================================
//
//  Batman (Atari Games, 1990/91) MiSTer FPGA core: top-level glue.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.  Structure follows the Skull &
//  Crossbones MiSTer core (GPL-3.0), itself inherited from the Badlands,
//  Vindicators, Xybots and Blasteroids cores; see NOTICE.md.
//
//  Connects batman_core (game PCB, video and JSA III sound board, in one
//  clk_sys domain with integer clock enables) to the MiSTer framework: PLL,
//  hps_io (ROM download, NVRAM, controls), CRT Adjust, arcade_video,
//  audio and the SDRAM pins.  clk_sys = 57.272727 MHz = 4 x the 14.318181 MHz
//  crystal; the pixel clock is clk_sys/8 = 7.159 MHz, giving a 456 x 262
//  raster with 336 x 240 visible at 59.92 Hz on a horizontal monitor.
//
//  Controls: Batman is a one-player game and reads its controls at 0x260000.
//  The board also wires a P2 set at 0x260002, which the game never reads;
//  pad 2 drives it anyway.  Fire / Jump / Start map to the board's FIRE /
//  ACTA / START1; ACTB is never read and is held released.  Coins and TILT
//  are read by the JSA III 6502, not the game PCB.  The OSD "Service" item
//  is the SELF TEST switch, a single net read by both boards.  The game has
//  no DIP switches: all settings live in the 28C16 EEPROM, saved as NVRAM on
//  ioctl index 2 (2048 bytes).  The MRA also carries MAME's batman-eeprom.bin
//  as a seed so a first boot without a save file gets the factory settings.
//
//============================================================================

`timescale 1ns/1ps

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1        = 0;
assign VGA_SCALER    = 0;
assign VGA_DISABLE   = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT= 0;
assign FB_FORCE_BLANK= 0;

assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

// Horizontal cabinet: the native raster is 336 x 240 on a 4:3 monitor.
wire  [1:0] ar  = status[122:121];
wire [11:0] arx = (ar == 2'd0) ? 12'd4 : 12'(ar - 1'd1);
wire [11:0] ary = (ar == 2'd0) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"Batman;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[4],Orientation,Original,Flip;",
	"O[22:20],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer;",
	"-;",
	// CRT Adjust (rmonic79's MiSTer-CRT-Adjust, batman_analog_adjust.sv): an
	// On/Off and three amounts, all two's complement.  Off is a bit-exact
	// bypass, so HDMI is untouched unless the stage is On.  H1 hides the
	// amounts while the stage is not running (Off, or the scandoubler forced).
	"P1,CRT Adjust;",
	"P1-;",
	"P1O[23],CRT Adjust,Off,On;",
	"H1P1O[28:24],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[35:29],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,+49,+50,+51,+52,+53,+54,+55,+56,+57,+58,+59,+60,+61,+62,+63,-64,-63,-62,-61,-60,-59,-58,-57,-56,-55,-54,-53,-52,-51,-50,-49,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[41:36],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	// The SELF TEST switch, labelled "Service" because it opens the service
	// menu (coinage, difficulty and so on, stored in the EEPROM).  The /SERVICE
	// button and TILT have no OSD entry and are held released.
	"O[6],Service,Off,On;",
	"-;",
	"T[0],Reset;",
	// The J1 list is the pad order and replaces the OSD's button names, so its
	// length decides how many buttons are mapped; the MRA's <buttons> element
	// must match it.  Names follow the game's self test ("START/FIRE", "JUMP").
	"J1,Fire,Jump,Start,Coin;",
	"jn,A,B,Start,Select;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire        direct_video;
wire [21:0] gamma_bus;

wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;
wire        ioctl_wait;
wire        ioctl_upload, ioctl_upload_req;
wire  [7:0] ioctl_upload_index, ioctl_din;

wire [31:0] joystick_0, joystick_1;

// ============================================================================
//  The index-0 ROM download stream (the MRA's part order must match)
// ============================================================================
// Decoded by batman_rom_loader.sv.  These localparams are unused here; they
// keep the map visible at the top of the core for checking against the MRA.
//
//   stream base  size       region    device(s)                          read from
//   0x000000     0x0C0000   maincpu   6 x 27C010 at 10R 7R 9/10R 6R 9R 5R SDRAM
//   0x0C0000     0x020000   chars     1 x 1 Mbit at 10M                  BRAM
//   0x0E0000     0x100000   tiles     8 x 1 Mbit at 15/16 R M F C        SDRAM (reordered)
//   0x1E0000     0x100000   sprites   8 x 1 Mbit at 13/14 R M F C        SDRAM (reordered)
//   0x2E0000     0x010000   jsa:cpu   1 x 27C512 at 12C                  BRAM
//   0x2F0000     0x080000   jsa:oki1  4 x 1 Mbit at 19E 17E 15E 12E      SDRAM
//   0x370000     0x000800   eeprom    factory seed for the 28C16         BRAM
//   (index 2)    0x000800   eeprom    28C16 at 12R, NVRAM save/restore   BRAM
//
// The MRA ships raw ROM bytes.  MAME inverts `tiles` and `sprites` after
// loading; this core applies the board's own active-low sense in the video RTL.
localparam [26:0] ROM_SZ_MAINCPU  = 27'h0C0000;   // stream 0x000000
localparam [26:0] ROM_SZ_CHARS    = 27'h020000;   // stream 0x0C0000, BRAM
localparam [26:0] ROM_SZ_TILES    = 27'h100000;   // stream 0x0E0000, scattered
localparam [26:0] ROM_SZ_SPRITES  = 27'h100000;   // stream 0x1E0000, scattered
localparam [26:0] ROM_SZ_JSA_CPU  = 27'h010000;   // stream 0x2E0000, BRAM
localparam [26:0] ROM_SZ_JSA_OKI  = 27'h080000;   // stream 0x2F0000
localparam [26:0] NVRAM_SZ_EEPROM = 27'h000800;   // ioctl index 2

// CRT Adjust master enable, declared here because status_menumask reads it.
// The read rate assumes the native 15 kHz pixel rate, so the stage stays off
// while the framework forces the scandoubler.
wire crt_enable = status[23] & ~forced_scandoubler;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),

	.buttons(buttons),
	.status(status),
	// H1 = hide while set: the CRT Adjust amounts vanish while the stage is idle.
	.status_menumask({14'd0, ~crt_enable, 1'b0}),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	// NVRAM: the 28C16 image, index 2, 2048 bytes.
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(ioctl_upload_index),
	.ioctl_din(ioctl_din),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;               // 57.272727 MHz
wire clk_sdram;             // same rate, phase-shifted for the SDRAM_CLK pin
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.locked(pll_locked)
);

// SDRAM clock pin from the phase-shifted PLL output (rtl/pll/pll_0002.v).  The
// phase is the one the sibling Atari cores use at the same clock rate.
assign SDRAM_CLK = clk_sdram;

// `reset` is the OSD / system reset for the game.  `~pll_locked` alone is
// init_reset, the only reset the SDRAM controller may see.
wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

///////////////////////   CONTROLS   /////////////////////////////

// MiSTer joystick bits: [0]=Right [1]=Left [2]=Down [3]=Up, then the J1 list:
// [4]=Fire [5]=Jump [6]=Start [7]=Coin.
//
// batman_core takes the joystick as {up, down, left, right} (0x260000 D15:12)
// and the buttons in the board's FIRE / ACTA / ACTB order.  ACTB is wired on
// the board but never read, so it has no pad button.  START is D8 of each
// player's port.
wire [3:0] p1_joy   = {joystick_0[3], joystick_0[2], joystick_0[1], joystick_0[0]};
wire [3:0] p2_joy   = {joystick_1[3], joystick_1[2], joystick_1[1], joystick_1[0]};
wire       p1_b1    = joystick_0[4];
wire       p1_b2    = joystick_0[5];
wire       p1_b3    = 1'b0;
wire       p1_start = joystick_0[6];
wire       p2_b1    = joystick_1[4];
wire       p2_b2    = joystick_1[5];
wire       p2_b3    = 1'b0;
wire       p2_start = joystick_1[6];

// Coins are read by the JSA III 6502 (/RDIO D1 = COIN1, D0 = COIN2), not by the
// game PCB.  Pad 1's Coin is COIN1.
wire coin1 = joystick_0[7];
wire coin2 = joystick_1[7];

// SELF TEST is one net read by both boards (game PCB 0x260010 D6 and the JSA
// III); the OSD calls it "Service".  /SERVICE and TILT are held released.
wire self_test = status[6];
wire service   = 1'b0;
wire tilt      = 1'b0;

///////////////////////   CORE   /////////////////////////////////

wire        ce_pix;
wire  [7:0] core_r, core_g, core_b;
wire        core_hs, core_vs, core_hb, core_vb;
wire [10:0] core_pix_index;      // palette index (for simulation only)
wire        core_rom_loaded;
wire        cctr1, cctr2;
wire signed [15:0] aud_l, aud_r;

batman_core u_core
(
	.clk_sys(clk_sys), .reset(reset), .init_reset(~pll_locked),

	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_index(ioctl_index), .ioctl_wait(ioctl_wait),
	.ioctl_upload(ioctl_upload), .ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(ioctl_upload_index), .ioctl_din(ioctl_din),

	.self_test(self_test), .service(service), .tilt(tilt),
	.p1_joy(p1_joy), .p2_joy(p2_joy),
	.p1_b1(p1_b1), .p1_b2(p1_b2), .p1_b3(p1_b3), .p1_start(p1_start),
	.p2_b1(p2_b1), .p2_b2(p2_b2), .p2_b3(p2_b3), .p2_start(p2_start),
	.coin1(coin1), .coin2(coin2),

	// The two coin-counter solenoids, driven by the JSA III.  MiSTer has no
	// sink for them.
	.cctr1(cctr1), .cctr2(cctr2),

	.ce_pix(ce_pix), .vga_r(core_r), .vga_g(core_g), .vga_b(core_b),
	.hsync(core_hs), .vsync(core_vs), .hblank(core_hb), .vblank(core_vb),
	.pix_index(core_pix_index),

	.aud_l(aud_l), .aud_r(aud_r),
	.rom_loaded(core_rom_loaded),

	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH), .SDRAM_CKE(SDRAM_CKE), .SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE)
);

///////////////////////   AUDIO   ////////////////////////////////

// The JSA III output is MONO; both channels carry one signal.
assign AUDIO_S = 1'b1;              // signed samples
assign AUDIO_L = aud_l;
assign AUDIO_R = aud_r;

///////////////////////   VIDEO   ////////////////////////////////

wire [7:0] adj_r, adj_g, adj_b;
wire       adj_hs, adj_vs, adj_hb, adj_vb, adj_ce;

// H_TOTAL is in ce_pix ticks: 456 pixels per line, 262 lines, and ce_pix is
// ce_7m = clk_sys/8 (CLK_PER_PIX = 8).  HPOS_MODE = 1 shifts the content and
// leaves HSync native; the H-Position limits it gives on this raster are in
// rtl/video/batman_analog_adjust.sv.
batman_analog_adjust #(
	.H_TOTAL(456), .V_TOTAL(262), .CLK_PER_PIX(8), .HPOS_MODE(1), .AW(11)
) u_analog_adjust
(
	.clk        (clk_sys),
	.ce_pix     (ce_pix),
	.osd_on     (crt_enable),
	.osd_hsize  (status[28:24]),
	.osd_hpos   (status[35:29]),
	.osd_vshift (status[41:36]),
	.r_in(core_r), .g_in(core_g), .b_in(core_b),
	.hs_in(core_hs), .vs_in(core_vs), .hb_in(core_hb), .vb_in(core_vb),
	.r_out(adj_r), .g_out(adj_g), .b_out(adj_b),
	.hs_out(adj_hs), .vs_out(adj_vs), .hb_out(adj_hb), .vb_out(adj_vb),
	.ce_out(adj_ce)
);

wire [2:0] fx = 3'b000;

wire       rotate_ccw = 1'b0;
wire       no_rotate  = 1'b1;
wire       flip       = status[4] & ~direct_video;
wire       video_rotated;

wire vga_de_raw;

// 336 pixels wide, 24-bit RGB, one pixel per 7M clock.
arcade_video #(.WIDTH(336), .DW(24)) arcade_video
(
	.clk_video (clk_sys),
	.ce_pix    (adj_ce),
	.RGB_in    ({adj_r, adj_g, adj_b}),
	.HBlank    (adj_hb),
	.VBlank    (adj_vb),
	.HSync     (adj_hs),
	.VSync     (adj_vs),

	.CLK_VIDEO (CLK_VIDEO),
	.CE_PIXEL  (CE_PIXEL),
	.VGA_R     (VGA_R),
	.VGA_G     (VGA_G),
	.VGA_B     (VGA_B),
	.VGA_HS    (VGA_HS),
	.VGA_VS    (VGA_VS),
	.VGA_DE    (vga_de_raw),
	.VGA_SL    (VGA_SL),

	.fx                 (fx),
	.forced_scandoubler (forced_scandoubler),
	.gamma_bus          (gamma_bus)
);

// video_freak SCALE encoding: 0 normal, 1 V-integer, 2 HV-Integer-, 4 HV-Integer.
wire [2:0] scale_sel = (status[22:20] == 3'd0) ? 3'd0 :
                       (status[22:20] == 3'd1) ? 3'd1 :
                       (status[22:20] == 3'd2) ? 3'd4 :
                                                 3'd2;

video_freak video_freak
(
	.CLK_VIDEO  (CLK_VIDEO),
	.CE_PIXEL   (CE_PIXEL),
	.VGA_VS     (VGA_VS),
	.HDMI_WIDTH (HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE     (VGA_DE),
	.VIDEO_ARX  (VIDEO_ARX),
	.VIDEO_ARY  (VIDEO_ARY),
	.VGA_DE_IN  (vga_de_raw),
	.ARX        (arx),
	.ARY        (ary),
	.CROP_SIZE  (12'd0),
	.CROP_OFF   (5'd0),
	.SCALE      (scale_sel)
);

screen_rotate screen_rotate (.*);

///////////////////////   STATUS LED   ///////////////////////////

assign LED_USER = ioctl_download;

// Nothing in the framework uses the palette index, the coin counters, the
// rom_loaded flag or the ROM-size localparams.
/* verilator lint_off UNUSEDSIGNAL */
wire _unused_emu = &{1'b0, core_pix_index, core_rom_loaded, cctr1, cctr2,
                     ROM_SZ_MAINCPU, ROM_SZ_CHARS, ROM_SZ_SPRITES,
                     ROM_SZ_TILES, ROM_SZ_JSA_CPU, ROM_SZ_JSA_OKI,
                     NVRAM_SZ_EEPROM, 1'b0};
/* verilator lint_on UNUSEDSIGNAL */

endmodule
