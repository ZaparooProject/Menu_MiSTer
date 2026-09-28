// Self-checking Menu horizontal re-timer test. The Menu input is fixed at
// CLK_VIDEO / 8 (54 MHz / 8 = 6.75 MHz) and has the narrow NTSC front porch,
// the binding worst case (PAL porches are wider at the same pixel rate).
// The positive range stops at effective +2 so all pixels drain before HS.
// Sweeps every UI step (effective -8..-1, +1, +2) plus the bypass path,
// asserting pixel identity, emitted count, active span and quiet HSYNC.
`timescale 1ns/1ps

module hretime_tb;

localparam integer H_ACTIVE = 352;
localparam integer H_FP = 12;
localparam integer H_SYNC = 32;
localparam integer H_BP = 33;
localparam integer H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
localparam integer V_ACTIVE = 3;
localparam integer V_TOTAL = 4;

reg clk = 0;
always #9.2593 clk = ~clk;

reg reset = 1;
reg [2:0] div = 0;
reg ce_in = 0;
reg [9:0] hcount = 0;
reg [3:0] vcount = 0;
reg enable = 0;
reg signed [3:0] scale = 0;

always @(posedge clk) begin
	if(reset) begin
		div <= 0;
		ce_in <= 0;
		hcount <= 0;
		vcount <= 0;
	end
	else begin
		ce_in <= (div == 3'd7);
		div <= div + 1'd1;
		if(div == 3'd7) begin
			if(hcount == H_TOTAL - 1) begin
				hcount <= 0;
				vcount <= (vcount == V_TOTAL - 1) ? 0 : vcount + 1'd1;
			end
			else hcount <= hcount + 1'd1;
		end
	end
end

wire hs_in = hcount >= H_ACTIVE + H_FP && hcount < H_ACTIVE + H_FP + H_SYNC;
wire vs_in = vcount == V_ACTIVE && hcount < H_SYNC;
wire de_in = hcount < H_ACTIVE && vcount < V_ACTIVE;
wire [23:0] din = {16'd0, hcount[7:0]};

wire ce_out, hs_out, vs_out, de_out;
wire [23:0] dout;
zaparoo_hretime dut
(
	.clk(clk), .reset(reset), .ce_in(ce_in), .enable(enable), .mode(2'd0), .scale(scale),
	.din(din), .hs_in(hs_in), .vs_in(vs_in), .de_in(de_in),
	.ce_out(ce_out), .dout(dout), .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out)
);

integer ticks = 0;
integer got = 0;
integer errors = 0;
integer first_tick = 0;
integer last_tick = 0;
integer expected_scale = 0;
reg checking = 0;
reg ce_out_d = 0;
reg hs_out_d = 0;

always @(posedge clk) begin
	ticks <= ticks + 1;
	ce_out_d <= ce_out;
	hs_out_d <= hs_out;

	if(ce_out_d && de_out) begin
		if(got == 0) first_tick <= ticks;
		if(checking && expected_scale == -8 && got != 0 && ticks - last_tick != 7) begin
			$display("FAIL: -8 progressive spacing %0d, expected 7 clocks", ticks - last_tick);
			errors <= errors + 1;
		end
		last_tick <= ticks;
		if(checking && dout[7:0] !== got[7:0]) begin
			$display("FAIL: scale %0d pixel %0d got %02x", expected_scale, got, dout[7:0]);
			errors <= errors + 1;
		end
		if(checking && hs_out) begin
			$display("FAIL: scale %0d has active pixels during HS", expected_scale);
			errors <= errors + 1;
		end
		got <= got + 1;
	end

	if(hs_out && !hs_out_d) begin
		if(checking && got != 0) begin
			integer expected_span;
			integer span;
			expected_span = ((H_ACTIVE - 1) * 8 * (64 + expected_scale)) / 64;
			span = last_tick - first_tick;
			if(got != H_ACTIVE) begin
				$display("FAIL: scale %0d emitted %0d pixels, expected %0d", expected_scale, got, H_ACTIVE);
				errors <= errors + 1;
			end
			if(span < expected_span - 5 || span > expected_span + 5) begin
				$display("FAIL: scale %0d active span %0d, expected %0d", expected_scale, span, expected_span);
				errors <= errors + 1;
			end
		end
		got <= 0;
		first_tick <= 0;
		last_tick <= 0;
	end
end

task wait_lines(input integer n);
	integer i;
	begin
		for(i = 0; i < n; i = i + 1) @(posedge hs_out);
	end
endtask

task exercise(input signed [3:0] requested_scale, input integer effective_scale);
	begin
		scale = requested_scale;
		expected_scale = effective_scale;
		wait_lines(5); // control latches at HS, then the FIFO/centering pipeline settles
		checking = 1;
		wait_lines(3);
		checking = 0;
	end
endtask

initial begin
	repeat(8) @(posedge clk);
	reset = 0;
	wait_lines(3);
	enable = 1;
	exercise(-8, -8);
	exercise(-7, -7);
	exercise(-6, -6);
	exercise(-5, -5);
	exercise(-4, -4);
	exercise(-3, -3);
	exercise(-2, -2);
	exercise(-1, -1);
	exercise(0, 1);
	exercise(1, 2);
	// Bypass (UI size 0): latched-skew-free passthrough, identity and span
	// at exact unity cadence.
	enable = 0;
	expected_scale = 0;
	wait_lines(5);
	checking = 1;
	wait_lines(3);
	checking = 0;
	wait_lines(3);
	if(errors == 0) $display("PASS: Menu hretime preserves pixels and safe analogue timing");
	else $fatal(1, "%0d hretime check(s) failed", errors);
	$finish;
end

initial begin
	#2_000_000_000;
	$fatal(1, "hretime timeout");
end

endmodule
