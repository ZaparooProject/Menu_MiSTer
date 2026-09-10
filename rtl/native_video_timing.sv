// Zaparoo native video timing: standard-definition CRT modes from 27 MHz.
//
//   mode 0: 352x240p60 (NTSC)    ce_pix = 27/4 = 6.75 MHz, 429x262,  15734.27 Hz
//   mode 1: 720x480i60 (CEA-861) ce_pix = 27/2 = 13.5 MHz, 858x525,  15734.27 Hz
//   mode 2: 352x288p50 (PAL)     ce_pix = 27/4 = 6.75 MHz, 432x312,  15625.00 Hz
//
// mode_in/h_offset_in/v_offset_in are quasi-static (two-flop synchronized by
// the caller) and are latched here at the field wrap so a mid-frame update
// can't corrupt sync. Offsets shift the image by repartitioning front/back
// porch; totals are invariant, so line/frame rates never move. Out-of-range
// offsets are clamped to the supported -8..+8 px / -8..+2 line window, which
// keeps every mode's effective porches at or above 2 px / 1 line.

module native_video_timing
(
	input  wire       clk,
	input  wire       ce_pix,
	input  wire       reset,

	input  wire        [1:0] mode_in,
	input  wire signed [7:0] h_offset_in,  // + = right, honored -8..+8 px
	input  wire signed [3:0] v_offset_in,  // + = down,  honored -8..+2 lines

	output reg  [1:0] mode,    // latched active mode; selects the ce_pix divider
	output reg        field,   // 480i field number, 0 in progressive modes
	output reg        hsync,
	output reg        vsync,
	output reg        hblank,
	output reg        vblank,
	output reg        de,
	output reg [9:0]  hcount,
	output reg [8:0]  vcount,  // line within the current field
	output reg        new_frame,
	output reg        new_line
);

localparam [1:0] MODE_NTSC = 2'd0;
localparam [1:0] MODE_480I = 2'd1;
localparam [1:0] MODE_PAL  = 2'd2;

// Per-mode parameter sets (Switchres ntsc/pal presets, CEA-861 for 480i).
// 480i: 525-line frame as two fields of 262 (field 0) and 263 (field 1)
// lines; field 1 additionally asserts vsync half a line late (see below).
reg [9:0] H_ACTIVE, H_FP, H_BP, H_TOTAL;
reg [6:0] H_SYNC;
reg [8:0] V_ACTIVE, V_FP, V_BP, V_TOTAL;
reg [4:0] V_SYNC;

always @* begin
	case(mode)
	MODE_480I: begin
		H_ACTIVE = 10'd720; H_FP = 10'd19; H_SYNC = 7'd62; H_BP = 10'd57; H_TOTAL = 10'd858;
		V_ACTIVE = 9'd240;  V_FP = 9'd4;   V_SYNC = 5'd3;
		V_BP     = field ? 9'd16 : 9'd15;
		V_TOTAL  = field ? 9'd263 : 9'd262;
	end
	MODE_PAL: begin
		H_ACTIVE = 10'd352; H_FP = 10'd11; H_SYNC = 7'd32; H_BP = 10'd37; H_TOTAL = 10'd432;
		V_ACTIVE = 9'd288;  V_FP = 9'd3;   V_SYNC = 5'd3;  V_BP = 9'd18;  V_TOTAL = 9'd312;
	end
	default: begin // MODE_NTSC
		H_ACTIVE = 10'd352; H_FP = 10'd12; H_SYNC = 7'd32; H_BP = 10'd33; H_TOTAL = 10'd429;
		V_ACTIVE = 9'd240;  V_FP = 9'd3;   V_SYNC = 5'd3;  V_BP = 9'd16;  V_TOTAL = 9'd262;
	end
	endcase
end

wire [1:0] next_mode = (mode_in == 2'd3) ? MODE_NTSC : mode_in;

function automatic signed [4:0] clamp_h(input signed [7:0] v);
	if (v > 8'sd8)       clamp_h = 5'sd8;
	else if (v < -8'sd8) clamp_h = -5'sd8;
	else                 clamp_h = v[4:0];
endfunction

function automatic signed [3:0] clamp_v(input signed [3:0] v);
	if (v > 4'sd2) clamp_v = 4'sd2;
	else           clamp_v = v;
endfunction

reg signed [4:0] h_offset;
reg signed [3:0] v_offset;

// Sync starts shift with the offset; two's-complement subtraction in
// unsigned arithmetic yields the correct result at both ends of the range.
wire [9:0] H_SYNC_START = H_ACTIVE + (H_FP - {{5{h_offset[4]}}, h_offset});
wire [9:0] H_SYNC_END   = H_SYNC_START + H_SYNC;
wire [8:0] V_SYNC_START = V_ACTIVE + (V_FP - {{5{v_offset[3]}}, v_offset});
wire [8:0] V_SYNC_END   = V_SYNC_START + V_SYNC;

// In 480i the odd field's vsync transitions half a scanline (H_TOTAL/2
// ce_pix clocks) after the line boundary, interleaving its scanlines
// between the even field's. Without this both fields land on the same
// scanlines (line pairing). vs_step fires once per line at the point a
// vsync edge may occur; vs_line is the line whose start (field 0) or
// midpoint (field 1) that edge aligns to.
wire       vs_step = field ? (hcount == (H_TOTAL >> 1) - 10'd1)
                           : (hcount == H_TOTAL - 10'd1);
wire [8:0] vs_line = field ? vcount : (vcount + 9'd1);

wire line_wrap  = (hcount == H_TOTAL - 10'd1);
wire field_wrap = line_wrap && (vcount == V_TOTAL - 9'd1);

always @(posedge clk) begin
	if(reset) begin
		mode      <= MODE_NTSC;
		field     <= 1'b0;
		h_offset  <= 5'sd0;
		v_offset  <= 4'sd0;
		hcount    <= 10'd0;
		vcount    <= 9'd0;
		hsync     <= 1'b0;
		vsync     <= 1'b0;
		hblank    <= 1'b0;
		vblank    <= 1'b0;
		de        <= 1'b1;
		new_frame <= 1'b0;
		new_line  <= 1'b0;
	end
	else if(ce_pix) begin
		reg next_hblank;
		reg next_vblank;

		new_frame <= 1'b0;
		new_line  <= 1'b0;

		if(line_wrap) begin
			hcount <= 10'd0;
			if(vcount == V_TOTAL - 9'd1) vcount <= 9'd0;
				else vcount <= vcount + 9'd1;
		end
		else begin
			hcount <= hcount + 10'd1;
		end

		// Mode and trims apply only at the field wrap, with counters at
		// zero, so every line of a field is cut from one parameter set.
		if(field_wrap) begin
			mode     <= next_mode;
			if(next_mode != MODE_480I) field <= 1'b0;
			h_offset <= clamp_h(h_offset_in);
			v_offset <= clamp_v(v_offset_in);
		end

		if(hcount == H_ACTIVE - 10'd1) hblank <= 1'b1;
			else if(line_wrap) hblank <= 1'b0;

		if(hcount == H_SYNC_START - 10'd1) hsync <= 1'b1;
			else if(hcount == H_SYNC_END - 10'd1) hsync <= 1'b0;

		if(vs_step) begin
			if(vs_line == V_SYNC_START) vsync <= 1'b1;
				else if(vs_line == V_SYNC_END) vsync <= 1'b0;
		end

		if(line_wrap) begin
			if(vcount == V_ACTIVE - 9'd1) vblank <= 1'b1;
				else if(vcount == V_TOTAL - 9'd1) vblank <= 1'b0;
		end

		if(hcount == H_ACTIVE - 10'd1) new_line <= 1'b1;
		// Field flips at the START of vblank, not the field wrap: the
		// reader preloads the next field's first lines right after
		// new_frame, so the field it reads must already be the one about
		// to be displayed. The vsync inside this blanking interval then
		// uses the new field's phase, which keeps the half-line
		// alternation intact (intervals stay exactly 262.5 lines).
		if(line_wrap && vcount == V_ACTIVE - 9'd1) begin
			new_frame <= 1'b1;
			field     <= (mode == MODE_480I) ? ~field : 1'b0;
		end

		next_hblank = hblank;
		if(hcount == H_ACTIVE - 10'd1) next_hblank = 1'b1;
			else if(line_wrap) next_hblank = 1'b0;

		next_vblank = vblank;
		if(line_wrap) begin
			if(vcount == V_ACTIVE - 9'd1) next_vblank = 1'b1;
				else if(vcount == V_TOTAL - 9'd1) next_vblank = 1'b0;
		end

		de <= ~next_hblank & ~next_vblank;
	end
end

endmodule
