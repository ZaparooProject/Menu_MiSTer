// Self-checking 480i /4 retimer test at the Menu's 54 MHz master rate.
// -8 shrink must retain all 720 pixels and never emit faster than one pixel
// every three master clocks, leaving time for a registered M10K read.
`timescale 1ns/1ps

module hretime_480i_tb;

localparam integer H_ACTIVE = 720;
localparam integer H_FP = 19;
localparam integer H_SYNC = 62;
localparam integer H_BP = 57;
localparam integer H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;

reg clk = 0;
always #9.2593 clk = ~clk; // 54 MHz
reg reset = 1;
reg [1:0] div = 0;
reg ce_in = 0;
reg [9:0] hcount = 0;
reg enable = 0;

always @(posedge clk) begin
	if(reset) begin
		div <= 0;
		ce_in <= 0;
		hcount <= 0;
	end
	else begin
		ce_in <= (div == 2'd3);
		div <= div + 1'd1;
		if(div == 2'd3) hcount <= (hcount == H_TOTAL - 1) ? 0 : hcount + 1'd1;
	end
end

wire hs_in = hcount >= H_ACTIVE + H_FP && hcount < H_ACTIVE + H_FP + H_SYNC;
wire de_in = hcount < H_ACTIVE;
wire ce_out, hs_out, de_out;
wire [23:0] dout;
zaparoo_hretime dut
(
	.clk(clk), .reset(reset), .ce_in(ce_in), .enable(enable), .mode(2'd1), .scale(-4'sd8),
	.din({14'd0, hcount}), .hs_in(hs_in), .vs_in(1'b0), .de_in(de_in),
	.ce_out(ce_out), .dout(dout), .hs_out(hs_out), .vs_out(), .de_out(de_out)
);

integer ticks = 0;
integer got = 0;
integer first_tick = 0;
integer last_tick = 0;
integer errors = 0;
reg checking = 0;
reg ce_out_d = 0;
reg hs_out_d = 0;

always @(posedge clk) begin
	ticks <= ticks + 1;
	ce_out_d <= ce_out;
	hs_out_d <= hs_out;
	if(ce_out_d && de_out) begin
		if(got == 0) first_tick <= ticks;
		if(checking && dout[9:0] !== got[9:0]) begin
			$display("FAIL: 480i pixel %0d got %03x", got, dout[9:0]);
			errors <= errors + 1;
		end
		if(checking && got != 0 && ticks - last_tick < 3) begin
			$display("FAIL: 480i spacing %0d clocks, need >= 3", ticks - last_tick);
			errors <= errors + 1;
		end
		if(checking && hs_out) begin
			$display("FAIL: 480i active pixel during HS");
			errors <= errors + 1;
		end
		last_tick <= ticks;
		got <= got + 1;
	end
	if(hs_out && !hs_out_d) begin
		if(checking && got != 0) begin
			if(got != H_ACTIVE) begin
				$display("FAIL: 480i emitted %0d pixels, expected %0d", got, H_ACTIVE);
				errors <= errors + 1;
			end
			if(last_tick - first_tick < 2512 || last_tick - first_tick > 2521) begin
				$display("FAIL: 480i active span %0d, expected about 2516", last_tick - first_tick);
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

initial begin
	repeat(8) @(posedge clk);
	reset = 0;
	wait_lines(3);
	enable = 1;
	wait_lines(6);
	checking = 1;
	wait_lines(3);
	checking = 0;
	if(errors == 0) $display("PASS: 480i -8 hretime preserves pixels with safe M10K cadence");
	else $fatal(1, "%0d 480i hretime check(s) failed", errors);
	$finish;
end

initial begin
	#2_000_000_000;
	$fatal(1, "480i hretime timeout");
end

endmodule
