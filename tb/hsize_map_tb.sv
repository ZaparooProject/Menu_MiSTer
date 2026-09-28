// Exhaustive check of the H-size -> retimer control mapping: every UI step
// (-8..+2) against every mode. This is the only place the "480i bypasses
// even with a nonzero stored size" rule is asserted in simulation.
`timescale 1ns/1ps

module hsize_map_tb;

reg        [1:0] mode = 0;
reg signed [7:0] h_size = 0;
wire             enable;
wire signed [3:0] scale;

zaparoo_hsize_map dut (.mode(mode), .h_size(h_size), .enable(enable), .scale(scale));

integer errors = 0;
integer m, s;
reg exp_en;
reg signed [3:0] exp_scale;

initial begin
	for (m = 0; m < 4; m = m + 1) begin
		for (s = -8; s <= 2; s = s + 1) begin
			mode = m[1:0];
			h_size = s[7:0];
			#1;
			exp_en = (s != 0) && (m != 1);
			if (enable !== exp_en) begin
				errors = errors + 1;
				$display("FAIL: mode %0d size %0d enable %b, expected %b", m, s, enable, exp_en);
			end
			if (exp_en) begin
				// hretime zero-skip: effective = scale + (scale >= 0 ? 1 : 0)
				exp_scale = (s < 0) ? s[3:0] : (s - 1);
				if (scale !== exp_scale) begin
					errors = errors + 1;
					$display("FAIL: mode %0d size %0d scale %0d, expected %0d", m, s, scale, exp_scale);
				end
			end
		end
	end
	if (errors == 0) $display("PASS: hsize map covers every UI step, unity off, 480i bypass");
	else $fatal(1, "%0d hsize map check(s) failed", errors);
	$finish;
end

initial begin
	#100000; $fatal(1, "hsize map test timeout");
end

endmodule
