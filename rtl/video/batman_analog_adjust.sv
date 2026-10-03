// Adapted for Batman from the Skull & Crossbones core's rtl/video/skullxbo_analog_adjust.sv (GPL-3.0); see NOTICE.md
// Analog-output alignment stage (logic unchanged from the Skull & Crossbones, Badlands and
// Toobin' cores): CRT H-Size / H-Position and analog VGA H-Shift / V-Shift, following the
// approach in rmonic79's Arcade-Raiden_MiSTer.
//
// Sits between batman_core and arcade_video.  It never touches the core's own timing, so
// the game cannot observe it.
//   H-Shift / V-Shift  move the sync relative to the picture (delayed HSync / VSync taps).
//   H-Position         moves the picture inside an unchanged HSync.
//   H-Size             resamples the line so every pixel is wider or narrower by the same
//                      amount (see analog_hsize.sv).
// All OSD fields are two's complement, decoded with $signed().
//
// H-Size accumulator: period = 64 + hsize units, where 64 units = CLK_PER_PIX clocks, and
// acc += 64/CLK_PER_PIX per clock, so each OSD step is 1/64 (1.56%) of a pixel.
// The top level sets H_TOTAL = 456, V_TOTAL = 262, CLK_PER_PIX = 8 (ce_7m); the defaults
// below are the Skull & Crossbones values.

module batman_analog_adjust #(
	parameter int H_TOTAL     = 912,   // ce_pix ticks per line
	parameter int V_TOTAL     = 262,   // lines per frame
	parameter int CLK_PER_PIX = 4      // clk_sys cycles per ce_pix
) (
	input  logic       clk,
	input  logic       ce_pix,

	// OSD, all two's complement
	input  logic [4:0] osd_hsize,      // CRT H-Size        +15 / -16
	input  logic [6:0] osd_hpos,       // CRT H-Position    +63 / -64
	input  logic [5:0] osd_hshift,     // Analog VGA H-Shift +31 / -32
	input  logic [5:0] osd_vshift,     // Analog VGA V-Shift +31 / -32

	input  logic [7:0] r_in, g_in, b_in,
	input  logic       hs_in, vs_in, hb_in, vb_in,

	output logic [7:0] r_out, g_out, b_out,
	output logic       hs_out, vs_out, hb_out, vb_out,
	output logic       ce_out
);

	localparam [7:0]  ACC_STEP = 8'(64 / CLK_PER_PIX);
	localparam [15:0] HT       = 16'(H_TOTAL);
	localparam [15:0] VT       = 16'(V_TOTAL);
	localparam int    HTW      = $clog2(H_TOTAL);
	localparam int    VTW      = $clog2(V_TOTAL);

	// ---------------- H-Shift: delay HSync by N pixels ----------------
	// A negative shift is a delay of H_TOTAL-|N| (the previous line's sync), so the
	// shift register spans a whole line.
	logic [5:0] hshift_d;
	always_ff @(posedge clk) if (ce_pix) hshift_d <= osd_hshift;
	wire        hsh_neg = hshift_d[5];
	wire  [5:0] hsh_mag = hsh_neg ? (6'd0 - hshift_d) : hshift_d;
	// verilator lint_off UNUSEDSIGNAL
	wire [15:0] hshift_wide = hsh_neg ? (HT - {10'd0, hsh_mag}) : {10'd0, hsh_mag};
	// verilator lint_on UNUSEDSIGNAL
	wire [HTW-1:0] hshift_tap = hshift_wide[HTW-1:0];   // < H_TOTAL by construction

	logic [H_TOTAL-1:0] hs_shreg;
	logic               hs_shifted;
	always_ff @(posedge clk) if (ce_pix) begin
		hs_shreg   <= {hs_shreg[H_TOTAL-2:0], hs_in};
		hs_shifted <= (hshift_tap == '0) ? hs_in : hs_shreg[hshift_tap - 1'b1];
	end

	// ---------------- V-Shift: delay VSync by N lines ----------------
	logic hs_in_d;
	always_ff @(posedge clk) if (ce_pix) hs_in_d <= hs_in;
	wire  line_tick = ce_pix & hs_in & ~hs_in_d;

	logic [5:0] vshift_d;
	always_ff @(posedge clk) if (line_tick) vshift_d <= osd_vshift;
	wire        vsh_neg = vshift_d[5];
	wire  [5:0] vsh_mag = vsh_neg ? (6'd0 - vshift_d) : vshift_d;
	// verilator lint_off UNUSEDSIGNAL
	wire [15:0] vshift_wide = vsh_neg ? (VT - {10'd0, vsh_mag}) : {10'd0, vsh_mag};
	// verilator lint_on UNUSEDSIGNAL
	wire [VTW-1:0] vshift_tap = vshift_wide[VTW-1:0];   // < V_TOTAL by construction

	logic [V_TOTAL-1:0] vs_shreg;
	logic               vs_shifted;
	always_ff @(posedge clk) if (line_tick) begin
		vs_shreg   <= {vs_shreg[V_TOTAL-2:0], vs_in};
		vs_shifted <= (vshift_tap == '0) ? vs_in : vs_shreg[vshift_tap - 1'b1];
	end

	// ---------------- H-Size: read-rate accumulator ----------------
	logic signed [4:0] hsize_s;
	always_ff @(posedge clk) if (ce_pix) hsize_s <= osd_hsize;
	wire hsize_active = (hsize_s != 5'sd0);

	wire  [7:0] rd_period = 8'd64 + {{3{hsize_s[4]}}, hsize_s};   // 48..79
	logic [7:0] rd_acc;
	wire        rd_tick = (rd_acc + ACC_STEP) >= rd_period;

	// Re-phase the read on the emitted (shifted) sync so H-Shift and H-Size agree.
	logic hs_shifted_d;
	always_ff @(posedge clk) hs_shifted_d <= hs_shifted;
	wire  shifted_hs_rise = hs_shifted & ~hs_shifted_d;

	always_ff @(posedge clk) begin
		if      (shifted_hs_rise) rd_acc <= 8'd0;
		else if (rd_tick)         rd_acc <= rd_acc + ACC_STEP - rd_period;
		else                      rd_acc <= rd_acc + ACC_STEP;
	end

	wire rd_ce = hsize_active ? rd_tick : ce_pix;

	// ---------------- H-Position ----------------
	logic signed [8:0] hoffset;
	always_ff @(posedge clk) if (ce_pix) hoffset <= {{2{osd_hpos[6]}}, osd_hpos};

	// ---------------- resampler ----------------
	// Fed the shifted syncs, so its bypass path carries H/V-Shift through unchanged.
	analog_hsize #(.AW(11)) u_hsize (
		.clk      (clk),
		.pxl_cen  (ce_pix),
		.pxl2_cen (rd_ce),
		.hsize    (hsize_s),
		.hoffset  (hoffset),
		.r_in     (r_in), .g_in (g_in), .b_in (b_in),
		.hs_in    (hs_shifted),
		.vs_in    (vs_shifted),
		.hb_in    (hb_in | vb_in),
		.vb_in    (vb_in),
		.r_out    (r_out), .g_out (g_out), .b_out (b_out),
		.hs_out   (hs_out), .vs_out (vs_out),
		.hb_out   (hb_out), .vb_out (vb_out)
	);

	assign ce_out = rd_ce;

endmodule
