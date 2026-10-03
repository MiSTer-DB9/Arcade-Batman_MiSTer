`timescale 1ns/1ps
//============================================================================
//  Batman colour RAM at 6A/6B: 2048 x 16 at 0x2E0000-0x2E0FFF, shared by the
//  video scan and the 68000.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//  Structure follows skullxbo_cram.sv of the Skull & Crossbones MiSTer core
//  (GPL-3.0); see NOTICE.md.
//
//  Word: bit 15 = I, the intensity LSB shared by all three guns (the schematic
//  wires it to D0 of all three R2R ladders); bits 14-10 R, 9-5 G, 4-0 B.
//
//  CPU sharing follows two VAD option bits (reg 0x0A), both set by Batman:
//    O_DCDMA  (bit 10): the RAM is cycled twice per pixel; the scan uses the
//             first half and the CPU the second, so no pixel is ever stolen.
//             When clear, a CPU access takes the scan's cycle and the colour
//             holds the previous value (counted in `steal`).
//    OCRDTACK (bit 4): CPU writes wait for their slot before /VDTACK; when
//             clear, writes are acknowledged at once.  Reads always wait.
//  The 8-bit mode (OCRDWE, reg 0x0A bit 6) and the O_DCDMA/OCRDTACK = 0 paths
//  are real options that Batman never selects, so the game never exercises
//  them.
//
//  The DAC sheet has no blanking gate, so the colour output latch is cleared
//  during blanking here.
//============================================================================

module batman_cram #(
	// VAD reg 0x0A bit 6.  0 = 16-bit colour RAM (Batman), 1 = 8-bit.
	parameter bit OCRDWE_8BIT = 1'b0
)(
	input  logic        clk,
	input  logic        reset,
	input  logic        ce,            // one pulse per pixel (ce_7m)
	input  logic        pix_half,      // 0 = the scan's half of the pixel

	// ---- the video read port ---------------------------------------------
	input  logic [10:0] pix_index,     // {CRA11, CRA10..CRA1} from batman_mixer
	input  logic        blank,         // HBLANK | VBLANK

	// ---- the CPU port (0x2E0000-0x2E0FFF, one 16-bit word per cycle) ------
	input  logic        cpu_cs,
	input  logic        cpu_we,
	input  logic  [1:0] cpu_ds,        // {/WU, /WL} as byte enables, active high
	input  logic [10:0] cpu_a,         // word index (A11:A1)
	input  logic [15:0] cpu_din,
	output logic [15:0] cpu_dout,
	output logic        cpu_grant,     // -> /VDTACK (active high here)

	// ---- VAD reg 0x0A option bits that control CPU sharing ---------------
	input  logic        o_dcdma,       // bit 10, 1 on Batman
	input  logic        ocrdtack,      // bit  4, 1 on Batman
	// ---- preload port, for simulation -------------------------------------
	input  logic        init_wr,
	input  logic [10:0] init_a,
	input  logic [15:0] init_d,

	// ---- outputs ----------------------------------------------------------
	output logic [15:0] colour,        // latched colour word to the DACs
	output logic [10:0] pix_index_out, // the index behind `colour`
	output logic [15:0] steal          // scan cycles taken by the CPU
);

	// ===================================================================
	//  Storage: two byte lanes with one write address, duplicated per reader
	// ===================================================================
	// Byte lanes avoid a read-modify-write for the byte mask; with that and
	// three read addresses Quartus built the RAM from logic and the design
	// failed to route.  Each reader (scan, CPU) has its own copy taking the same
	// writes, so every copy is a plain one-write / one-read M10K and the scan
	// path gets no extra register.
	logic [7:0] crs_hi [0:2047];      // the scan's copy
	logic [7:0] crs_lo [0:2047];
	logic [7:0] crc_hi [0:2047];      // the CPU's copy
	logic [7:0] crc_lo [0:2047];

	// In 8-bit mode only the low byte exists; the high byte reads as zero.
	wire wmask_hi = cpu_ds[1] & ~OCRDWE_8BIT;
	wire wmask_lo = cpu_ds[0];

	// ---- the slot ---------------------------------------------------------
	logic        cpu_done_r, cpu_rd_r;
	logic [15:0] rq, cpu_rq;

	wire cpu_want  = cpu_cs & ~cpu_done_r;
	wire cpu_slot  = o_dcdma ? (cpu_want &  pix_half)
	                         : (cpu_want & ~pix_half);
	wire scan_slot = o_dcdma ? ~pix_half : (~pix_half & ~cpu_want);

	// One write address per cycle: preload, then CPU, then scan.  The preload
	// port is for simulation and never runs with the CPU live.
	wire [10:0] aa  = init_wr ? init_a : (cpu_slot ? cpu_a : pix_index);
	wire [15:0] ad  = init_wr ? init_d : cpu_din;
	wire        awe = cpu_slot & cpu_we;
	wire        awh = init_wr | (awe & wmask_hi);
	wire        awl = init_wr | (awe & wmask_lo);

	// `rq` holds through a stolen cycle, as a single-ported array would.
	always_ff @(posedge clk) begin
		if (awh) crs_hi[aa] <= ad[15:8];
		if (awl) crs_lo[aa] <= ad[7:0];
		if (scan_slot) rq <= {crs_hi[pix_index], crs_lo[pix_index]};
	end

	always_ff @(posedge clk) begin
		if (awh) crc_hi[aa] <= ad[15:8];
		if (awl) crc_lo[aa] <= ad[7:0];
		if (cpu_slot) cpu_rq <= {crc_hi[cpu_a], crc_lo[cpu_a]};
	end

	assign cpu_dout = OCRDWE_8BIT ? {8'h00, cpu_rq[7:0]} : cpu_rq;

	// ---- the CPU cycle -----------------------------------------------------
	always_ff @(posedge clk) begin
		if (reset) begin
			cpu_done_r <= 1'b0;
			cpu_rd_r   <= 1'b0;
			steal      <= 16'd0;
		end else begin
			if (!cpu_cs) begin
				cpu_done_r <= 1'b0;
				cpu_rd_r   <= 1'b0;
			end else begin
				// OCRDTACK clear: a write is answered without waiting.
				if (cpu_we && !ocrdtack) cpu_done_r <= 1'b1;
				if (cpu_slot)            cpu_done_r <= 1'b1;
				if (cpu_slot)            cpu_rd_r   <= 1'b1;
			end
			if (cpu_slot && !o_dcdma && !pix_half)
				steal <= steal + 16'd1;
		end
	end

	assign cpu_grant = cpu_cs & (cpu_we ? cpu_done_r : cpu_rd_r);

	// ---- the colour output latch, cleared during blanking -------------------
	always_ff @(posedge clk) begin
		if (reset) begin
			colour        <= 16'h0000;
			pix_index_out <= 11'd0;
		end else if (ce) begin
			colour        <= blank ? 16'h0000 : rq;
			pix_index_out <= blank ? 11'd0    : pix_index;
		end
	end

endmodule
