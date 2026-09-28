// Horizontal analogue re-timer for the Menu CRT output.
//
// Each source pixel is emitted once, but is held for a slightly different
// number of CLK_VIDEO cycles. This adjusts the analogue picture width without
// resampling or changing normal HDMI/ascal. Raw direct-video HDMI follows the
// same analogue branch. The 54 MHz Menu source is fixed at eight CLK_VIDEO
// cycles per 240p/PAL pixel and four per 480i pixel.
//
// The source is intentionally based on jtframe_hretime by Andrea Bogazzi and
// the CRT-Adjust module by Umberto Parisi. It is kept as a Menu-specific
// implementation: no build macros or per-core parameters are required here.

module zaparoo_hretime
(
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_in,
	input  wire        enable,
	input  wire  [1:0] mode,
	// Two's-complement -8..+7. With enable set, 0..+7 map to +1..+8;
	// Menu clamps the externally supplied setting to a safe maximum of +2.
	input  wire signed [3:0] scale,

	input  wire [23:0] din,
	input  wire        hs_in,
	input  wire        vs_in,
	input  wire        de_in,

	output wire        ce_out,
	output wire [23:0] dout,
	output wire        hs_out,
	output wire        vs_out,
	output wire        de_out
);

localparam integer STEP     = 64;
// At 480i/-8 the re-timer buffers 90 pixels before its first output. 128
// entries preserves that leading delay without wrapping the source line.
localparam integer DEPTH    = 128;
localparam integer HW       = 10;
localparam integer MAX_BASE = 8;
localparam integer SLOG  = $clog2(STEP);
localparam integer AW    = $clog2(DEPTH);
localparam integer ACCW  = $clog2(MAX_BASE * (STEP + 8)) + 1;
localparam integer PW    = SLOG + HW;
localparam integer SDEP  = 1 << $clog2((DEPTH * MAX_BASE) / 2 + 1);
localparam integer SAW   = $clog2(SDEP);

(* ramstyle = "no_rw_check" *) reg [23:0] pixel_mem [0:DEPTH-1];
(* ramstyle = "no_rw_check" *) reg  [1:0] sync_mem [0:SDEP-1];

reg [23:0] mem_rd = 0;
reg [23:0] fifo_dout = 0;
reg [23:0] din_l = 0;
reg [AW-1:0] wptr = 0;
reg [AW-1:0] rptr = 0;
reg [HW-1:0] wcnt = 0;
reg [HW-1:0] rcnt = 0;
reg [HW-1:0] nactive = 0;
reg [ACCW-1:0] acc = 0;
reg [SAW-1:0] sync_wp = 0;
reg hs_l = 0;
reg ce_slow = 0;
reg started = 0;
reg fifo_de = 0;
reg de_l = 0;
reg hs_dly = 0;
reg vs_dly = 0;
reg hs_b = 0;   // bypass HS, latched with din_l/de_l so the
reg vs_b = 0;   // bypass path stays skew-free vs data and DE
reg enable_l = 0;
reg signed [3:0] scale_l = 0;
reg [3:0] base_l = MAX_BASE;

// Skip a zero scale while enabled: the four-bit input expresses the sixteen
// non-zero steps -8..-1 and +1..+8, matching the frontend selector.
wire signed [4:0] effective_scale =
	{scale_l[3], scale_l} + {4'd0, ~scale_l[3]};
wire [ACCW-1:0] next_acc = acc + STEP[ACCW-1:0];
wire [3:0] base_from_mode = (mode == 2'd1) ? 4'd4 : 4'd8;

reg [ACCW-1:0] period = MAX_BASE * STEP;
reg [HW-1:0] extra_px = 0;
reg [SAW-1:0] sync_dly = 1;

always @(posedge clk) begin : delay_pipeline
	reg [4:0] abs_scale;
	reg [PW-1:0] product;
	reg [HW+4:0] delay_full;
	reg [HW+3:0] delay_half;
	if(reset) begin
		period <= MAX_BASE * STEP;
		extra_px <= 0;
		sync_dly <= 1;
	end
	else begin
		abs_scale = effective_scale[4] ? -effective_scale : effective_scale;
		period <= (base_l == 4'd4) ? 4 * (STEP + effective_scale) :
			8 * (STEP + effective_scale);
		product = nactive * abs_scale;
		extra_px <= product[PW-1:SLOG];
		delay_full = extra_px * base_l;
		delay_half = delay_full[HW+4:1];
		sync_dly <= delay_half >= SDEP ? {SAW{1'b1}} :
			(delay_half == 0 ? {{SAW-1{1'b0}}, 1'b1} : delay_half[SAW-1:0]);
	end
end

wire bypass = reset | ~enable_l;
wire hs_pos = hs_in & ~hs_l;
wire push = ce_in & de_in & ~bypass;
wire pop = ce_slow & started & (rcnt < wcnt);

assign ce_out = bypass ? ce_in : ce_slow;
assign hs_out = bypass ? hs_b : hs_dly;
assign vs_out = bypass ? vs_b : vs_dly;
assign de_out = bypass ? de_l : fifo_de;
assign dout = bypass ? din_l : fifo_dout;

always @(posedge clk) begin
	if(reset) begin
		hs_l <= 0;
		ce_slow <= 0;
		wptr <= 0;
		wcnt <= 0;
		nactive <= 0;
		acc <= 0;
		enable_l <= 0;
		scale_l <= 0;
		base_l <= MAX_BASE;
		din_l <= 0;
		de_l <= 0;
		hs_b <= 0;
		vs_b <= 0;
	end
	else begin
		hs_l <= hs_in;
		ce_slow <= 0;
		if(hs_pos) begin
			acc <= 0;
		end
		else if(next_acc >= period) begin
			acc <= next_acc - period;
			ce_slow <= 1;
		end
		else begin
			acc <= next_acc;
		end

		// The current source line feeds the re-timed FIFO. Latching the control
		// and source cadence at hsync prevents a live update from tearing a line.
		if(hs_pos) begin
			wptr <= 0;
			wcnt <= 0;
			enable_l <= enable;
			scale_l <= scale;
			base_l <= base_from_mode;
			if(wcnt != 0) nactive <= wcnt;
		end
		else if(push) begin
			pixel_mem[wptr] <= din;
			wptr <= wptr + 1'd1;
			wcnt <= wcnt + 1'd1;
		end

		if(ce_in) begin
			din_l <= din;
			de_l <= de_in;
			hs_b <= hs_in;
			vs_b <= vs_in;
		end
	end
end

always @(posedge clk) begin
	if(reset) begin
		mem_rd <= 0;
		rptr <= 0;
		rcnt <= 0;
		started <= 0;
		fifo_de <= 0;
		fifo_dout <= 0;
		sync_wp <= 0;
		hs_dly <= 0;
		vs_dly <= 0;
	end
	else begin
		// M10K read is registered. With the 54 MHz Menu cadence, the fastest
		// permitted output (480i, -8) is one pixel per three clocks, so data
		// settles before every pop.
		mem_rd <= pixel_mem[rptr];
		if(hs_pos) begin
			rptr <= 0;
			rcnt <= 0;
			started <= 0;
			fifo_de <= 0;
			fifo_dout <= 0;
		end
		else begin
			// Shrink needs the truncated fractional lead (extra_px floors
			// nactive*|scale|/64) plus one pixel so the reader never pops a
			// slot the cycle after its push, before the registered RAM read
			// has settled: odd scales otherwise corrupt the line tail.
			if(!started && wcnt > (effective_scale[4] ? extra_px + 1'd1 : {HW{1'b0}}))
				started <= 1;
			if(ce_slow) begin
				fifo_de <= pop;
				if(pop) begin
					fifo_dout <= mem_rd;
					rptr <= rptr + 1'd1;
					rcnt <= rcnt + 1'd1;
				end
				else begin
					fifo_dout <= 0;
				end
			end
		end

		sync_mem[sync_wp] <= {hs_in, vs_in};
		sync_wp <= sync_wp + 1'd1;
		{hs_dly, vs_dly} <= sync_mem[sync_wp - sync_dly];
	end
end

endmodule
