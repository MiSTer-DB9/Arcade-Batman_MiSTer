// Adapted for Batman from the Skull & Crossbones core's rtl/sound/skullxbo_oki.sv (GPL-3.0); see NOTICE.md
`timescale 1ns/1ps
//============================================================================
//  batman_oki - the OKI MSM6295 ADPCM chip at 10E on the JSA III audio board.
//  The ROM banking around it is in batman_snd_adpcm.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  Derived from rtl/lib/oki/klax_oki6295.v (Klax MiSTer core,
//  GPL-2.0-or-later).  The ADPCM state machine, phrase-table and command
//  protocols, volume table, mix/clamp arithmetic and status byte are that
//  file's.  Changes: sample ROM is read from SDRAM through a byte client; the
//  chip clock is the integer enable ce_1m19 (clk_sys/48 = 1.193182 MHz, the
//  board's 1193K net) instead of a fractional accumulator; and the SS pin is
//  live (Klax ties it high).
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version (GPL-2.0-or-later material relicensed upward, as its
//  licence permits).  See LICENSE, NOTICE.md.
//
//  Pins: SS (7) = VFREQ, 0 -> /165 = 7231.4 Hz (reset value, what the game
//  uses), 1 -> /132 = 9039.3 Hz.  RESET (8) = /OKIRES.  WR (3) = /WRV $2A00,
//  RD (2) = /RDV $2800, CS (4) tied to GND.  XT (5) = 1193K.
//
//  ROM client: the chip raises oki_req with a stable oki_addr and holds both;
//  the arbiter pulses oki_ack for one clk with the byte on oki_data.  One
//  request at a time; a sample period is 7920 clk_sys cycles, far more than
//  the few bytes it needs.
//
//  Command protocol (as MAME): a byte with bit 7 set latches a sample number
//  and the next byte gives the voice mask (7:4) and volume (3:0); otherwise
//  bits 6:3 stop voices.  Starting a voice that is already playing is ignored.
//  Status = $F0 | playing voices.  Writes are edge-qualified so one bus write
//  is one command byte.  /WRV also fires on a read of $2A00 (the decode ignores
//  R/W); that is passed through as on the board.
//============================================================================

module batman_oki
(
	input  logic        clk,
	input  logic        ce_1m19,      // XT (pin 5) = 1.193182 MHz
	input  logic        okires_n,     // RESET (pin 8), 0 = held in reset
	input  logic        vfreq,        // SS (pin 7): 0 -> /165, 1 -> /132

	input  logic        wr_stb,       // WR (pin 3) = /WRV  ($2A00)
	input  logic  [7:0] wr_data,      // SD7:0 at that access
	input  logic        rd_stb,       // RD (pin 2) = /RDV  ($2800)
	output logic  [7:0] rd_data,      // the status byte

	// ---- sample-ROM byte client (VA17:0, banked by batman_snd_adpcm) ----
	output logic        oki_req,
	output logic [17:0] oki_addr,
	input  logic        oki_ack,
	input  logic  [7:0] oki_data,

	output logic signed [15:0] audio   // DAO (pin 36), to the analogue filter
);

	// Phrase addresses are 18 bits (MAME masks to 0x3FFFF); nibble addresses
	// carry one extra LSB.
	localparam int PHRASE_AW = 18;

	wire reset = ~okires_n;

	// ================= the sample tick =======================================
	// One ce_1m19 is one XT period, so only the chip's own divider is left:
	// /165 with SS low, /132 with SS high.  divisor follows the pin live.
	wire [7:0] divisor = vfreq ? 8'd132 : 8'd165;
	logic [7:0] div_ctr;
	logic       sample_tick;

	always_ff @(posedge clk) begin
		if (reset) begin
			div_ctr     <= 8'd0;
			sample_tick <= 1'b0;
		end else begin
			sample_tick <= 1'b0;
			if (ce_1m19) begin
				if (div_ctr >= divisor - 8'd1) begin
					div_ctr     <= 8'd0;
					sample_tick <= 1'b1;
				end else begin
					div_ctr <= div_ctr + 8'd1;
				end
			end
		end
	end

	// ================= voice state ===========================================
	logic [PHRASE_AW:0] voice_nibble_addr [0:3];
	logic [PHRASE_AW:0] voice_stop_nibble [0:3];
	logic signed [11:0] voice_signal      [0:3];
	logic         [5:0] voice_step        [0:3];
	logic         [3:0] voice_volume      [0:3];
	logic         [3:0] voice_active;

	assign rd_data = {4'b1111, voice_active};

	// ================= command register state ================================
	logic       wr_en_d;
	wire        wr_strobe = wr_stb & ~wr_en_d;

	logic [6:0] pending_cmd;
	logic       pending_valid;

	logic       start_pending;
	logic [6:0] start_sample;
	logic [3:0] start_mask;
	logic [3:0] start_volume;

	// ================= the shared ROM read port ==============================
	logic [7:0] rom_q;
	wire        rom_take = oki_req & oki_ack;      // the byte lands this clk

	// ================= phrase-table fetch FSM ================================
	logic [2:0] table_state;
	logic [2:0] table_count;
	logic [6:0] table_sample;
	logic [3:0] table_mask;
	logic [3:0] table_volume;
	logic [PHRASE_AW-1:0] table_start;
	logic [PHRASE_AW-1:0] table_stop;

	localparam logic [2:0] TABLE_IDLE    = 3'd0;
	localparam logic [2:0] TABLE_REQ     = 3'd1;
	localparam logic [2:0] TABLE_WAIT    = 3'd2;
	localparam logic [2:0] TABLE_CAPTURE = 3'd3;
	localparam logic [2:0] TABLE_DONE    = 3'd4;

	// ================= playback FSM ==========================================
	logic       tick_req;
	logic [2:0] play_state;
	logic [2:0] play_voice;
	logic               play_nibble_lsb;   // only bit 0 of the fetched
	                                       // nibble address is needed downstream
	logic signed [15:0] mix_acc;
	// Multiply operands registered between PLAY_DECODE and PLAY_MIX: the
	// product plus the add in one cycle missed timing at 57.27 MHz.
	// mix_signal holds the full 13-bit next_signal so the result is exact.
	logic signed [12:0] mix_signal;
	logic         [3:0] mix_volume;

	localparam logic [2:0] PLAY_IDLE   = 3'd0;
	localparam logic [2:0] PLAY_REQ    = 3'd1;
	localparam logic [2:0] PLAY_WAIT   = 3'd2;
	localparam logic [2:0] PLAY_DECODE = 3'd3;
	localparam logic [2:0] PLAY_NEXT   = 3'd4;
	localparam logic [2:0] PLAY_DONE   = 3'd5;
	localparam logic [2:0] PLAY_MIX    = 3'd6;

	// Playback has priority on the ROM port; the table fetch retries until the
	// port is free.  (Klax's arbitration, kept.)
	wire [1:0] pv = play_voice[1:0];
	wire play_rom_req = (play_state == PLAY_REQ) && !play_voice[2] && voice_active[pv];
	wire tick_consume = (play_state == PLAY_IDLE) && tick_req;

	// ---------------- the ADPCM primitives, from klax_oki6295.v -------------
	function automatic logic signed [12:0] clip12(input logic signed [13:0] value);
		if      (value >  14'sd2047) clip12 =  13'sd2047;
		else if (value < -14'sd2048) clip12 = -13'sd2048;
		else                         clip12 =  value[12:0];
	endfunction

	function automatic logic [5:0] clip_step(input logic [5:0] step,
	                                         input logic signed [4:0] delta);
		logic signed [7:0] sum;
		// $signed() on the zero-extended step keeps the addition signed so a
		// negative delta sign-extends instead of zero-extending.
		sum = $signed({2'b00, step}) + {{3{delta[4]}}, delta};
		if      (sum < 8'sd0)  clip_step = 6'd0;
		else if (sum > 8'sd48) clip_step = 6'd48;
		else                   clip_step = sum[5:0];
	endfunction

	function automatic logic signed [4:0] step_delta(input logic [2:0] code);
		case (code)
			3'd0, 3'd1, 3'd2, 3'd3: step_delta = -5'sd1;
			3'd4:                   step_delta =  5'sd2;
			3'd5:                   step_delta =  5'sd4;
			3'd6:                   step_delta =  5'sd6;
			default:                step_delta =  5'sd8;
		endcase
	endfunction

	// floor(16 * 1.1^step), MAME's oki_adpcm_state table.
	function automatic logic [11:0] step_value(input logic [5:0] step);
		case (step)
			6'd0:  step_value = 12'd16;    6'd1:  step_value = 12'd17;
			6'd2:  step_value = 12'd19;    6'd3:  step_value = 12'd21;
			6'd4:  step_value = 12'd23;    6'd5:  step_value = 12'd25;
			6'd6:  step_value = 12'd28;    6'd7:  step_value = 12'd31;
			6'd8:  step_value = 12'd34;    6'd9:  step_value = 12'd37;
			6'd10: step_value = 12'd41;    6'd11: step_value = 12'd45;
			6'd12: step_value = 12'd50;    6'd13: step_value = 12'd55;
			6'd14: step_value = 12'd60;    6'd15: step_value = 12'd66;
			6'd16: step_value = 12'd73;    6'd17: step_value = 12'd80;
			6'd18: step_value = 12'd88;    6'd19: step_value = 12'd97;
			6'd20: step_value = 12'd107;   6'd21: step_value = 12'd118;
			6'd22: step_value = 12'd130;   6'd23: step_value = 12'd143;
			6'd24: step_value = 12'd157;   6'd25: step_value = 12'd173;
			6'd26: step_value = 12'd190;   6'd27: step_value = 12'd209;
			6'd28: step_value = 12'd230;   6'd29: step_value = 12'd253;
			6'd30: step_value = 12'd279;   6'd31: step_value = 12'd307;
			6'd32: step_value = 12'd337;   6'd33: step_value = 12'd371;
			6'd34: step_value = 12'd408;   6'd35: step_value = 12'd449;
			6'd36: step_value = 12'd494;   6'd37: step_value = 12'd544;
			6'd38: step_value = 12'd598;   6'd39: step_value = 12'd658;
			6'd40: step_value = 12'd724;   6'd41: step_value = 12'd796;
			6'd42: step_value = 12'd876;   6'd43: step_value = 12'd963;
			6'd44: step_value = 12'd1060;  6'd45: step_value = 12'd1166;
			6'd46: step_value = 12'd1282;  6'd47: step_value = 12'd1411;
			default: step_value = 12'd1552;
		endcase
	endfunction

	function automatic logic signed [13:0] adpcm_delta(input logic [5:0] step,
	                                                   input logic [3:0] nibble);
		logic [11:0] stepval;
		logic [12:0] diff;
		stepval = step_value(step);
		// stepval/2, /4 and /8 truncate SEPARATELY -- MAME's integer division.
		diff = {1'b0, (stepval >> 3)};
		if (nibble[0]) diff = diff + {1'b0, (stepval >> 2)};
		if (nibble[1]) diff = diff + {1'b0, (stepval >> 1)};
		if (nibble[2]) diff = diff + {1'b0, stepval};
		if (nibble[3]) adpcm_delta = -$signed({1'b0, diff});
		else           adpcm_delta =  $signed({1'b0, diff});
	endfunction

	// MAME okim6295 volume table: ~3 dB steps, indexes >= 9 are silent.
	function automatic logic signed [6:0] volume_level(input logic [3:0] volume);
		case (volume)
			4'h0: volume_level = 7'sd32;   4'h1: volume_level = 7'sd22;
			4'h2: volume_level = 7'sd16;   4'h3: volume_level = 7'sd11;
			4'h4: volume_level = 7'sd8;    4'h5: volume_level = 7'sd6;
			4'h6: volume_level = 7'sd4;    4'h7: volume_level = 7'sd3;
			4'h8: volume_level = 7'sd2;    default: volume_level = 7'sd0;
		endcase
	endfunction

	// signal * volume_fraction with MAME's truncate-toward-zero rounding, then
	// a >>>5 scale.
	function automatic logic signed [14:0] mix_dac(input logic signed [12:0] sig,
	                                               input logic [3:0] vol);
		logic signed [19:0] prod;
		prod = sig * volume_level(vol);
		mix_dac = 15'((prod + (prod[19] ? 20'sd31 : 20'sd0)) >>> 5);
	endfunction

	// clamp(16 * sum): one full-volume voice spans the full output range;
	// concurrent loud voices saturate, exactly like MAME's stream conversion.
	function automatic logic signed [15:0] mix_clamp(input logic signed [15:0] acc);
		if      (acc >  16'sd2047) mix_clamp = 16'sh7FFF;
		else if (acc < -16'sd2048) mix_clamp = 16'sh8000;
		else                       mix_clamp = 16'(acc <<< 4);
	endfunction

	// ---------------- the machine -------------------------------------------
	always_ff @(posedge clk) begin
		if (reset) begin
			wr_en_d          <= 1'b0;
			pending_cmd      <= 7'd0;
			pending_valid    <= 1'b0;
			start_pending    <= 1'b0;
			start_sample     <= 7'd0;
			start_mask       <= 4'd0;
			start_volume     <= 4'd0;
			table_state      <= TABLE_IDLE;
			table_count      <= 3'd0;
			table_sample     <= 7'd0;
			table_mask       <= 4'd0;
			table_volume     <= 4'd0;
			table_start      <= '0;
			table_stop       <= '0;
			voice_active     <= 4'd0;
			tick_req         <= 1'b0;
			play_state       <= PLAY_IDLE;
			play_voice       <= 3'd0;
			play_nibble_lsb  <= 1'b0;
			mix_acc          <= 16'sd0;
			mix_signal       <= 13'sd0;
			mix_volume       <= 4'd0;
			audio            <= 16'sd0;
			oki_req          <= 1'b0;
			oki_addr         <= '0;
			rom_q            <= 8'd0;
			for (int v = 0; v < 4; v++) begin
				voice_nibble_addr[v] <= '0;
				voice_stop_nibble[v] <= '0;
				voice_signal[v]      <= 12'sd0;
				voice_step[v]        <= 6'd0;
				voice_volume[v]      <= 4'd0;
			end
		end else begin
			wr_en_d  <= wr_stb;
			tick_req <= sample_tick | (tick_req & ~tick_consume);

			// ---- the ROM client: one request in flight ----
			if (rom_take) begin
				rom_q   <= oki_data;
				oki_req <= 1'b0;
			end

			// ================= phrase-table fetch FSM =================
			case (table_state)
				TABLE_IDLE: begin
					if (start_pending) begin
						start_pending <= 1'b0;
						table_sample  <= start_sample;
						table_mask    <= start_mask;
						table_volume  <= start_volume;
						table_count   <= 3'd0;
						table_start   <= '0;
						table_stop    <= '0;
						table_state   <= TABLE_REQ;
					end
				end

				TABLE_REQ: begin
					if (!play_rom_req && !oki_req) begin
						oki_addr    <= {8'd0, table_sample, 3'b000}
						               + {15'd0, table_count};
						oki_req     <= 1'b1;
						table_state <= TABLE_WAIT;
					end
				end

				TABLE_WAIT: begin
					if (rom_take) table_state <= TABLE_CAPTURE;
				end

				TABLE_CAPTURE: begin
					case (table_count)
						3'd0: table_start[17:16] <= rom_q[1:0];
						3'd1: table_start[15:8]  <= rom_q;
						3'd2: table_start[7:0]   <= rom_q;
						3'd3: table_stop[17:16]  <= rom_q[1:0];
						3'd4: table_stop[15:8]   <= rom_q;
						3'd5: table_stop[7:0]    <= rom_q;
						default: begin end
					endcase
					if (table_count == 3'd5) begin
						table_state <= TABLE_DONE;
					end else begin
						table_count <= table_count + 3'd1;
						table_state <= TABLE_REQ;
					end
				end

				TABLE_DONE: begin
					if (table_start < table_stop) begin
						for (int v = 0; v < 4; v++) begin
							if (table_mask[v] && !voice_active[v]) begin
								voice_active[v]      <= 1'b1;
								voice_nibble_addr[v] <= {table_start, 1'b0};
								voice_stop_nibble[v] <= {table_stop,  1'b1};
								voice_signal[v]      <= 12'sd0;
								voice_step[v]        <= 6'd0;
								voice_volume[v]      <= table_volume;
							end
						end
					end
					table_state <= TABLE_IDLE;
				end

				default: table_state <= TABLE_IDLE;
			endcase

			// ================= playback FSM =================
			case (play_state)
				PLAY_IDLE: begin
					if (tick_req) begin
						mix_acc    <= 16'sd0;
						play_voice <= 3'd0;
						play_state <= PLAY_REQ;
					end
				end

				PLAY_REQ: begin
					if (play_voice[2]) begin
						play_state <= PLAY_DONE;
					end else if (voice_active[pv]) begin
						if (!oki_req) begin
							play_nibble_lsb  <= voice_nibble_addr[pv][0];
							oki_addr         <= voice_nibble_addr[pv][PHRASE_AW:1];
							oki_req          <= 1'b1;
							play_state       <= PLAY_WAIT;
						end
					end else begin
						play_state <= PLAY_NEXT;
					end
				end

				PLAY_WAIT: begin
					if (rom_take) play_state <= PLAY_DECODE;
				end

				PLAY_DECODE: begin
					logic         [3:0] nibble;
					logic signed [13:0] sum14;
					logic signed [12:0] next_signal;
					logic         [5:0] next_step;
					logic [PHRASE_AW+1:0] next_nibble_addr;

					nibble = play_nibble_lsb ? rom_q[3:0] : rom_q[7:4];
					sum14  = 14'({{2{voice_signal[pv][11]}}, voice_signal[pv]})
					       + adpcm_delta(voice_step[pv], nibble);
					next_signal      = clip12(sum14);
					next_step        = clip_step(voice_step[pv], step_delta(nibble[2:0]));
					next_nibble_addr = {1'b0, voice_nibble_addr[pv]} + 20'd1;

					voice_signal[pv]      <= next_signal[11:0];
					voice_step[pv]        <= next_step;
					voice_nibble_addr[pv] <= next_nibble_addr[PHRASE_AW:0];

					mix_signal <= next_signal;
					mix_volume <= voice_volume[pv];

					if (next_nibble_addr > {1'b0, voice_stop_nibble[pv]})
						voice_active[pv] <= 1'b0;

					play_state <= PLAY_MIX;
				end

				PLAY_MIX: begin
					mix_acc    <= mix_acc + 16'(mix_dac(mix_signal, mix_volume));
					play_state <= PLAY_NEXT;
				end

				PLAY_NEXT: begin
					play_voice <= play_voice + 3'd1;
					play_state <= PLAY_REQ;
				end

				PLAY_DONE: begin
					audio      <= mix_clamp(mix_acc);
					play_state <= PLAY_IDLE;
				end

				default: play_state <= PLAY_IDLE;
			endcase

			// ================= command register =================
			// Placed after the FSMs so a stop command on the same clk as a
			// phrase-table completion wins (the stop was issued later).
			if (wr_strobe) begin
				if (pending_valid) begin
					// Second half of a two-byte start command.  ANY byte is
					// consumed here, even one with bit 7 set: the voice mask is
					// simply bits 7:4.
					pending_valid <= 1'b0;
					start_pending <= 1'b1;
					start_sample  <= pending_cmd;
					start_mask    <= wr_data[7:4];
					start_volume  <= wr_data[3:0];
				end else if (wr_data[7]) begin
					pending_cmd   <= wr_data[6:0];
					pending_valid <= 1'b1;
				end else begin
					// Silence command: stop the voices in bits 6:3, including
					// ones whose start is still in the table-fetch pipeline.
					for (int v = 0; v < 4; v++) begin
						if (wr_data[3 + v]) begin
							voice_active[v] <= 1'b0;
							table_mask[v]   <= 1'b0;
							start_mask[v]   <= 1'b0;
						end
					end
				end
			end
		end
	end

	// RD (pin 2) puts the status byte on SD7:0; the read mux in batman_sound
	// applies that gate, so the strobe is unused here (a read has no side
	// effect on this part).  It is a port so the pin is visible.
	wire _unused_oki = &{ 1'b0, rd_stb };

endmodule
