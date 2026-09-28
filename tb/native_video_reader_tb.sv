// System-level testbench for native_video_top (timing + reader) against a
// behavioral DDR model and tb/dcfifo_sim.sv. Verifies the v2 DDR contract:
//
//   - no writer (word0 == 0): core stays inactive, only control polls issued
//   - v2 frames: correct buffer base, 176-word line bursts, mode + h/v
//     offsets parsed from word1 and latched by the timing module
//   - double buffering: counter change switches buffer base
//   - writer stop: word0 -> 0 drops active (frame_ready) again
//   - stale DDR: a magic-carrying block already present at reset with a
//     frozen counter never activates (this is what a previous core leaves
//     behind); a counter advance under it does activate; no magic never does
//   - PAL (mode 2): 288 line fetches
//   - 480i (mode 1): two 180-beat bursts per line, source line = 2*line+field,
//     alternating per field; FIFO never overflows
//   - DDR timeout: unresponsive bus drops active instead of latching stale
//
// Run: tb/run.sh

`timescale 1ns/1ps

module native_video_reader_tb;

reg clk_sys = 0; always #5       clk_sys = ~clk_sys;  // 100 MHz DDR-side
reg clk_vid = 0; always #9.2593 clk_vid = ~clk_vid;   // 54 MHz
reg reset = 1;

wire [1:0] vmode;
wire       vfield;

// ce_pix divider mirrors menu.sv: /8 progressive, /4 480i.
reg [2:0] ce_div = 0;
reg       ce_pix = 0;
always @(posedge clk_vid) begin
	if (reset) ce_div <= 3'd0;
		else  ce_div <= ce_div + 3'd1;
	ce_pix <= (vmode == 2'd1) ? (ce_div[1:0] == 2'd0) : (ce_div == 3'd0);
end

// ---- DDR model -------------------------------------------------------------
localparam [28:0] CTRL_ADDR   = 29'h07400000;
localparam [28:0] BUF0_V2     = 29'h07400200;
localparam [28:0] BUF1_V2     = 29'h07430000;
localparam [63:0] PIX_DATA    = 64'h00FFAA55_00FFAA55; // B,G,R,X = 55,AA,FF,00

wire        ddr_rd;
wire [28:0] ddr_addr;
wire  [7:0] ddr_burstcnt;
reg  [63:0] ddr_dout = 0;
reg         ddr_dout_ready = 0;

reg  [63:0] ctrl_q = 64'd0;   // {word1, word0} as published by the "writer"
reg         respond_en = 1;

integer req_n = 0;
reg [28:0] req_addr [0:199999];
reg [7:0]  req_cnt  [0:199999];

reg [28:0] cur_addr = 0;
integer    cur_left = 0;
integer    lat = 0;

always @(posedge clk_sys) begin
	ddr_dout_ready <= 0;
	if (ddr_rd) begin
		req_addr[req_n] = ddr_addr;
		req_cnt[req_n]  = ddr_burstcnt;
		req_n = req_n + 1;
		if (respond_en) begin
			cur_addr <= ddr_addr;
			cur_left <= ddr_burstcnt;
			lat      <= 3;
		end
	end
	else if (cur_left != 0) begin
		if (lat != 0) lat <= lat - 1;
		else begin
			ddr_dout       <= (cur_addr == CTRL_ADDR) ? ctrl_q : PIX_DATA;
			ddr_dout_ready <= 1;
			cur_addr       <= cur_addr + 29'd1;
			cur_left       <= cur_left - 1;
		end
	end
end

// ---- DUT --------------------------------------------------------------------
wire [7:0] vga_r, vga_g, vga_b;
wire       new_frame, active;

native_video_top dut
(
	.clk_sys        (clk_sys),
	.clk_vid        (clk_vid),
	.ce_pix         (ce_pix),
	.reset          (reset),

	.ddr_busy       (1'b0),
	.ddr_burstcnt   (ddr_burstcnt),
	.ddr_addr       (ddr_addr),
	.ddr_dout       (ddr_dout),
	.ddr_dout_ready (ddr_dout_ready),
	.ddr_rd         (ddr_rd),
	.ddr_din        (),
	.ddr_be         (),
	.ddr_we         (),

	.vga_r          (vga_r),
	.vga_g          (vga_g),
	.vga_b          (vga_b),
	.vga_hs         (),
	.vga_vs         (),
	.vga_de         (),
	.vga_hblank     (),
	.vga_vblank     (),
	.vga_vcount     (),
	.vga_new_frame  (new_frame),
	.vga_mode       (vmode),
	.vga_field      (vfield),
	.active         (active)
);

// ---- helpers -----------------------------------------------------------------
integer errors = 0;

task check(input string name, input integer got, input integer exp);
	begin
		if (got !== exp) begin
			errors = errors + 1;
			$display("FAIL  %-36s got %0d (0x%0h), expected %0d (0x%0h)", name, got, got, exp, exp);
		end
		else $display("pass  %-36s %0d", name, got);
	end
endtask

task wait_frames(input integer n);
	repeat (n) @(posedge new_frame);
endtask

// Publish a control block: word0 = (counter << 2) | buffer.
task publish(input bit magic, input [3:0] pmode, input signed [7:0] hoff,
             input signed [3:0] voff, input integer counter, input bit buffer);
	begin
		ctrl_q = {magic ? 16'h5A50 : 16'h0000, hoff, voff, pmode,
		          counter[29:0], 1'b0, buffer};
	end
endtask

// Verify one whole frame's DDR request sequence: a control poll followed by
// nlines line fetches of bpl bursts of blen beats each, line l fetched from
// base + src*stride + b*blen, where src = l (progressive) or 2*l + field
// (intl set). Also asserts the FIFO never overflowed during the frame.
task check_frame_fetch(input string tag, input [28:0] base, input integer stride,
                       input integer nlines, input integer blen, input integer bpl,
                       input bit intl, output reg fld);
	integer s, l, b, idx, src;
	begin
		@(posedge new_frame);
		@(negedge clk_vid);
		fld = vfield;
		s   = req_n;
		dut.reader.line_fifo.peak_used      = 0;
		dut.reader.line_fifo.overflow_count = 0;
		@(posedge new_frame);
		check({tag, " fifo overflow-free"}, dut.reader.line_fifo.overflow_count, 0);
		$display("info  %s fifo peak occupancy: %0d / 1024 words", tag, dut.reader.line_fifo.peak_used);
		check({tag, " ctrl poll addr"}, req_addr[s], CTRL_ADDR);
		check({tag, " ctrl poll burst"}, req_cnt[s], 1);
		check({tag, " requests/frame"}, req_n >= s + 1 + nlines*bpl, 1);
		for (l = 0; l < nlines; l = l + 1) begin
			src = intl ? (2*l + fld) : l;
			for (b = 0; b < bpl; b = b + 1) begin
				idx = s + 1 + l*bpl + b;
				if (req_addr[idx] !== base + src*stride + b*blen || req_cnt[idx] !== blen[7:0]) begin
					errors = errors + 1;
					$display("FAIL  %s line %0d burst %0d: got addr 0x%0h cnt %0d, expected addr 0x%0h cnt %0d",
					         tag, l, b, req_addr[idx], req_cnt[idx], base + src*stride + b*blen, blen);
					l = nlines; b = bpl; // bail after first mismatch
				end
			end
		end
		$display("pass  %s frame fetch sequence (%0d lines x %0d bursts, field %0d)", tag, nlines, bpl, fld);
	end
endtask

// Sample vga_r at a given (hcount, vcount) pixel tick.
task sample_r(input integer hx, input integer vx, output [7:0] r);
	begin
		@(posedge clk_vid);
		while (!(ce_pix && dut.timing.hcount == hx[9:0] && dut.timing.vcount == vx[8:0] && dut.timing.de))
			@(posedge clk_vid);
		r = vga_r;
	end
endtask

reg [7:0] rs;
reg fld_a, fld_b;

// ---- test sequence ------------------------------------------------------------
initial begin
	repeat (20) @(posedge clk_sys);
	reset = 0;

	// Phase 0: no writer.
	$display("--- phase 0: no writer ---");
	wait_frames(3);
	check("idle: active low",            {31'd0, active}, 0);
	check("idle: only ctrl polls",       req_cnt[req_n-1], 1);
	check("idle: poll addr",             req_addr[req_n-1], CTRL_ADDR);

	// Phase 1: v2 writer, mode 0, offsets +5/-3, buffer 0.
	$display("--- phase 1: v2 mode 0 ---");
	publish(1, 4'd0, 8'sd5, -4'sd3, 1, 0);
	wait (active === 1'b1);
	wait_frames(2);
	check("v2: mode latched",            vmode, 0);
	check("v2: h_offset latched",        dut.timing.h_offset, 5);
	check("v2: v_offset latched",        dut.timing.v_offset, -3);
	check_frame_fetch("v2-buf0", BUF0_V2, 176, 240, 176, 1, 0, fld_a);
	sample_r(100, 100, rs); check("v2: interior pixel R",  rs, 8'hFF);
	sample_r(6,   100, rs); check("v2: paints to the edge", rs, 8'hFF);

	// Phase 2: counter advances with buffer 1.
	$display("--- phase 2: double buffer ---");
	publish(1, 4'd0, 8'sd5, -4'sd3, 2, 1);
	wait_frames(2);
	check_frame_fetch("v2-buf1", BUF1_V2, 176, 240, 176, 1, 0, fld_a);

	// Phase 3: writer stops.
	$display("--- phase 3: writer stop ---");
	ctrl_q = 64'd0;
	wait_frames(3);
	check("stop: active drops",          {31'd0, active}, 0);
	check("stop: mode reverts",          vmode, 0);

	// Phase 4: a block already present at reset is a previous core's DDR
	// leftovers, not a writer, and must never be painted.
	$display("--- phase 4: stale control block rejected ---");
	publish(1, 4'd0, 8'sd0, 4'sd0, 9, 0);
	reset = 1; repeat (20) @(posedge clk_sys); reset = 0;
	wait_frames(8);
	check("stale at reset: inactive",    {31'd0, active}, 0);
	sample_r(100, 100, rs); check("stale at reset: idle not DDR", rs !== 8'hFF, 1);

	// ...but a writer that then starts advancing the counter is real.
	publish(1, 4'd0, 8'sd0, 4'sd0, 10, 1);
	wait (active === 1'b1);
	$display("pass  stale block: counter advance activates");

	// No magic is rejected outright, however trusted the writer was.
	publish(0, 4'd0, 8'sd0, 4'sd0, 11, 0);
	wait_frames(4);
	check("no magic: active drops",      {31'd0, active}, 0);
	sample_r(100, 100, rs); check("no magic: idle not DDR", rs !== 8'hFF, 1);
	ctrl_q = 64'd0;
	wait_frames(3);

	// Phase 5: PAL.
	$display("--- phase 5: v2 mode 2 (PAL) ---");
	publish(1, 4'd2, 8'sd0, 4'sd0, 12, 0);
	wait (vmode === 2'd2);
	wait (active === 1'b1);
	wait_frames(2);
	check_frame_fetch("pal", BUF0_V2, 176, 288, 176, 1, 0, fld_a);

	// Phase 6: 480i.
	$display("--- phase 6: v2 mode 1 (480i) ---");
	publish(1, 4'd1, 8'sd0, 4'sd0, 13, 0);
	wait (vmode === 2'd1);
	wait_frames(2);
	check_frame_fetch("480i-a", BUF0_V2, 360, 240, 180, 2, 1, fld_a);
	wait_frames(1); // realign so the next measured field has opposite parity
	check_frame_fetch("480i-b", BUF0_V2, 360, 240, 180, 2, 1, fld_b);
	check("480i: both field parities seen", {31'd0, fld_a ^ fld_b}, 1);

	// Phase 7: DDR stops responding mid-session.
	$display("--- phase 7: DDR timeout ---");
	publish(1, 4'd0, 8'sd0, 4'sd0, 14, 0);
	wait (vmode === 2'd0);
	wait_frames(3);
	check("pre-timeout: active",         {31'd0, active}, 1);
	respond_en = 0;
	wait (active === 1'b0);
	$display("pass  timeout: active dropped");
	respond_en = 1;
	publish(1, 4'd0, 8'sd0, 4'sd0, 15, 0);
	wait (active === 1'b1);
	$display("pass  timeout: recovered after writer republish");

	// Phase 8: exact Slint extended PAL word, then wider signed trims.
	$display("--- phase 8: extended protocol ---");
	ctrl_q = {32'h5A5100F6, 30'd16, 1'b0, 1'b1};
	wait (vmode === 2'd2); wait_frames(3);
	check("extended PAL mode bits", vmode, 2);
	check("extended PAL signed v", dut.timing.v_offset, -3);
	check_frame_fetch("extended-pal", BUF1_V2, 176, 288, 176, 1, 0, fld_a);
	ctrl_q = {16'h5A51, -8'sd31, -6'sd14, 2'd0, 30'd17, 1'b0, 1'b0};
	wait (vmode === 2'd0); wait_frames(3);
	check("extended wide h", dut.timing.h_offset, -31);
	check("extended wide v", dut.timing.v_offset, -14);
	check("extended wide active", {31'd0, active}, 1);
	ctrl_q = {16'h5A51, 8'sd9, 6'sd2, 2'd1, 30'd18, 1'b0, 1'b1};
	wait (vmode === 2'd1); wait_frames(3);
	check("extended 480i h", dut.timing.h_offset, 9);
	check("extended 480i v", dut.timing.v_offset, 2);
	check_frame_fetch("extended-480i", BUF1_V2, 360, 240, 180, 2, 1, fld_a);

	// Legacy mode nibble and clamp behavior remain intact.
	publish(1, 4'd0, 8'sd100, 4'sd7, 19, 0);
	wait (vmode === 2'd0); wait_frames(3);
	check("legacy h clamp preserved", dut.timing.h_offset, 8);
	check("legacy v clamp preserved", dut.timing.v_offset, 2);
	ctrl_q = {32'h5A520000, 30'd20, 1'b0, 1'b0};
	wait_frames(3);
	check("unknown magic rejected", {31'd0, active}, 0);

	if (errors == 0) $display("ALL CHECKS PASSED");
	else begin
		$display("%0d CHECK(S) FAILED", errors);
		$fatal(1);
	end
	$finish;
end

initial begin
	#3_000_000_000;
	$display("TIMEOUT");
	$fatal(1);
end

endmodule
