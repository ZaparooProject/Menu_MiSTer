// Self-checking testbench for native_video_timing (docs/native-video-plan.md §8).
//
// Measures, in exact ce_pix ticks, per mode: line period, hsync width,
// sync→active delay, active width, field period, vsync width, active lines
// per field — and for 480i: field alternation and the half-line vsync offset
// (both vsync intervals must be exactly 262.5 lines = 225225 ticks, which is
// impossible without the offset). Also exercises the h/v offset trims and
// their clamping.
//
// Run: tb/run.sh

`timescale 1ns/1ps

module native_video_timing_tb;

reg clk = 0;
always #18.5185 clk = ~clk;   // 27 MHz

reg reset = 1;

reg        [1:0] mode_in     = 2'd0;
reg signed [7:0] h_offset_in = 8'sd0;
reg signed [3:0] v_offset_in = 4'sd0;

wire [1:0] mode;
wire       field, hsync, vsync, hblank, vblank, de, new_frame, new_line;
wire [9:0] hcount;
wire [8:0] vcount;

// ce_pix divider mirrors menu.sv: /4 (6.75 MHz) progressive, /2 (13.5 MHz) 480i.
reg [1:0] ce_div = 0;
reg       ce_pix = 0;
always @(posedge clk) begin
	if (reset) ce_div <= 2'd0;
		else  ce_div <= ce_div + 2'd1;
	ce_pix <= (mode == 2'd1) ? ce_div[0] : (ce_div == 2'd0);
end

native_video_timing dut
(
	.clk         (clk),
	.ce_pix      (ce_pix),
	.reset       (reset),
	.mode_in     (mode_in),
	.h_offset_in (h_offset_in),
	.v_offset_in (v_offset_in),
	.mode        (mode),
	.field       (field),
	.hsync       (hsync),
	.vsync       (vsync),
	.hblank      (hblank),
	.vblank      (vblank),
	.de          (de),
	.hcount      (hcount),
	.vcount      (vcount),
	.new_frame   (new_frame),
	.new_line    (new_line)
);

// ---- monitor: everything in ce_pix ticks ---------------------------------
// DUT outputs are sampled one tick late, uniformly, so intervals are exact.
integer tick = 0;
reg hs_d = 0, vs_d = 0, de_d = 0;
reg await_de = 0;
reg vs_field = 0, vs_field_d = 0;

integer hs_rise_tick = 0, vs_rise_tick = 0, de_rise_tick = 0;
integer hs_period = 0, hs_width = 0;
integer de_width  = 0, hs_to_de = 0, vs_to_de = 0;
integer vs_period = 0, vs_period_d = 0, vs_width = 0;
integer de_lines = 0, de_lines_last = 0;
integer vs_count = 0;

always @(posedge clk) begin
	if (ce_pix) begin
		if (hsync & ~hs_d) begin
			hs_period    <= tick - hs_rise_tick;
			hs_rise_tick <= tick;
		end
		if (~hsync & hs_d) hs_width <= tick - hs_rise_tick;

		if (de & ~de_d) begin
			de_rise_tick <= tick;
			hs_to_de     <= tick - hs_rise_tick;
			de_lines     <= de_lines + 1;
			if (await_de) begin
				vs_to_de <= tick - vs_rise_tick;
				await_de <= 0;
			end
		end
		if (~de & de_d) de_width <= tick - de_rise_tick;

		if (vsync & ~vs_d) begin
			vs_period_d   <= vs_period;
			vs_period     <= tick - vs_rise_tick;
			vs_rise_tick  <= tick;
			de_lines_last <= de_lines;
			de_lines      <= 0;
			vs_field_d    <= vs_field;
			vs_field      <= field;
			await_de      <= 1;
			vs_count      <= vs_count + 1;
		end
		if (~vsync & vs_d) vs_width <= tick - vs_rise_tick;

		hs_d <= hsync;
		vs_d <= vsync;
		de_d <= de;
		tick <= tick + 1;
	end
end

// ---- helpers ---------------------------------------------------------------
integer errors = 0;

task check(input string name, input integer got, input integer exp);
	begin
		if (got !== exp) begin
			errors = errors + 1;
			$display("FAIL  %-32s got %0d, expected %0d", name, got, exp);
		end
		else $display("pass  %-32s %0d", name, got);
	end
endtask

// Wait n vsync rising edges (plenty for the field-wrap latch + a full
// measurable frame after any control change).
task settle(input integer n);
	integer target;
	begin
		target = vs_count + n;
		wait (vs_count >= target);
		@(posedge clk);
	end
endtask

// ---- test sequence ---------------------------------------------------------
initial begin
	repeat (8) @(posedge clk);
	reset = 0;

	// ---- mode 0: 352x240p60 NTSC --------------------------------------
	settle(3);
	$display("--- mode 0: 352x240p60 (line 63.556us, 15734.27 Hz, 60.05 Hz) ---");
	check("ntsc line period (px)",      hs_period,     429);
	check("ntsc hsync width (px)",      hs_width,      32);
	check("ntsc sync->active (px)",     hs_to_de,      65);     // 32 sync + 33 BP
	check("ntsc active width (px)",     de_width,      352);
	check("ntsc field period (px)",     vs_period,     429*262);
	check("ntsc vsync width (px)",      vs_width,      429*3);
	check("ntsc active lines",          de_lines_last, 240);
	check("ntsc vsync->active (px)",    vs_to_de,      429*19); // 3 sync + 16 BP
	check("ntsc field flat",            {31'd0, vs_field}, 0);

	// ---- mode 2: 352x288p50 PAL ----------------------------------------
	mode_in = 2'd2;
	settle(4);
	$display("--- mode 2: 352x288p50 (line 64.000us, 15625.00 Hz, 50.08 Hz) ---");
	check("pal line period (px)",       hs_period,     432);
	check("pal hsync width (px)",       hs_width,      32);
	check("pal sync->active (px)",      hs_to_de,      69);     // 32 sync + 37 BP
	check("pal active width (px)",      de_width,      352);
	check("pal field period (px)",      vs_period,     432*312);
	check("pal vsync width (px)",       vs_width,      432*3);
	check("pal active lines",           de_lines_last, 288);

	// ---- mode 1: 720x480i60 ---------------------------------------------
	mode_in = 2'd1;
	settle(5);
	$display("--- mode 1: 720x480i60 (line 63.556us, 15734.27 Hz, 59.94 Hz) ---");
	check("480i line period (px)",      hs_period,     858);
	check("480i hsync width (px)",      hs_width,      62);
	check("480i sync->active (px)",     hs_to_de,      119);    // 62 sync + 57 BP
	check("480i active width (px)",     de_width,      720);
	// Both vsync intervals = 262.5 lines exactly: proves the half-line
	// offset (integer field lengths would give 262*858 / 263*858).
	check("480i field period A (px)",   vs_period,     225225);
	check("480i field period B (px)",   vs_period_d,   225225);
	check("480i vsync width (px)",      vs_width,      858*3);
	check("480i active lines/field",    de_lines_last, 240);
	check("480i fields alternate",      {31'd0, vs_field ^ vs_field_d}, 1);

	// ---- offset trims + clamping (mode 0) -------------------------------
	mode_in = 2'd0;
	settle(4);
	$display("--- offset trims (mode 0) ---");

	h_offset_in = 8'sd8;    settle(4);
	check("h=+8  sync->active",         hs_to_de, 73);
	check("h=+8  active width",         de_width, 352);
	check("h=+8  line period",          hs_period, 429);
	h_offset_in = -8'sd8;   settle(4);
	check("h=-8  sync->active",         hs_to_de, 57);
	h_offset_in = 8'sd100;  settle(4);
	check("h=+100 clamps to +8",        hs_to_de, 73);
	h_offset_in = -8'sd100; settle(4);
	check("h=-100 clamps to -8",        hs_to_de, 57);
	h_offset_in = 8'sd0;

	v_offset_in = 4'sd2;    settle(4);
	check("v=+2  vsync->active",        vs_to_de, 429*21);
	check("v=+2  field period",         vs_period, 429*262);
	v_offset_in = -4'sd8;   settle(4);
	check("v=-8  vsync->active",        vs_to_de, 429*11);
	v_offset_in = 4'sd7;    settle(4);
	check("v=+7  clamps to +2",         vs_to_de, 429*21);
	v_offset_in = 4'sd0;

	// ---- mode change sanity: back to NTSC after everything --------------
	settle(4);
	check("ntsc restore line period",   hs_period, 429);
	check("ntsc restore sync->active",  hs_to_de,  65);
	check("ntsc restore field flat",    {31'd0, vs_field}, 0);

	if (errors == 0) $display("ALL CHECKS PASSED");
	else begin
		$display("%0d CHECK(S) FAILED", errors);
		$fatal(1);
	end
	$finish;
end

initial begin
	#2_000_000_000;  // 2 s simulated-time guard
	$display("TIMEOUT");
	$fatal(1);
end

endmodule
