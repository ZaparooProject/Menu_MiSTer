// Zaparoo native video wrapper: timing + RGBX8888 DDR reader.
//
// Mode and centering trims arrive from the launcher through the DDR control
// block (parsed by the reader in the ddr_clk domain). They are quasi-static:
// two-flop synchronized here into the video clock, then latched by the
// timing module at the field wrap.

module native_video_top
(
	input  wire        clk_sys,
	input  wire        clk_vid,
	input  wire        ce_pix,
	input  wire        reset,

	input  wire        ddr_busy,
	output wire  [7:0] ddr_burstcnt,
	output wire [28:0] ddr_addr,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output wire        ddr_rd,
	output wire [63:0] ddr_din,
	output wire  [7:0] ddr_be,
	output wire        ddr_we,

	output wire  [7:0] vga_r,
	output wire  [7:0] vga_g,
	output wire  [7:0] vga_b,
	output wire        vga_hs,
	output wire        vga_vs,
	output wire        vga_de,
	output wire        vga_hblank,
	output wire        vga_vblank,
	output wire  [8:0] vga_vcount,
	output wire        vga_new_frame,

	output wire  [1:0] vga_mode,   // active timing mode; selects ce_pix divider
	output wire        vga_field,  // 480i field number (VGA_F1)
	output wire        active
);

wire       tim_hs;
wire       tim_vs;
wire       tim_hblank;
wire       tim_vblank;
wire       tim_de;
wire [9:0] tim_hcount;
wire [8:0] tim_vcount;
wire       tim_new_frame;
wire       tim_new_line;
wire       tim_field;

wire  [1:0] rd_mode;
wire signed [7:0] rd_h_offset;
wire signed [3:0] rd_v_offset;

reg [1:0] mode_sync     [1:0];
reg [7:0] h_offset_sync [1:0];
reg [3:0] v_offset_sync [1:0];
always @(posedge clk_vid) begin
	mode_sync[0]     <= rd_mode;       mode_sync[1]     <= mode_sync[0];
	h_offset_sync[0] <= rd_h_offset;   h_offset_sync[1] <= h_offset_sync[0];
	v_offset_sync[0] <= rd_v_offset;   v_offset_sync[1] <= v_offset_sync[0];
end

native_video_timing timing
(
	.clk         (clk_vid),
	.ce_pix      (ce_pix),
	.reset       (reset),
	.mode_in     (mode_sync[1]),
	.h_offset_in ($signed(h_offset_sync[1])),
	.v_offset_in ($signed(v_offset_sync[1])),
	.mode        (vga_mode),
	.field       (tim_field),
	.hsync       (tim_hs),
	.vsync       (tim_vs),
	.hblank      (tim_hblank),
	.vblank      (tim_vblank),
	.de          (tim_de),
	.hcount      (tim_hcount),
	.vcount      (tim_vcount),
	.new_frame   (tim_new_frame),
	.new_line    (tim_new_line)
);

wire frame_ready;

native_video_reader reader
(
	.ddr_clk        (clk_sys),
	.ddr_busy       (ddr_busy),
	.ddr_burstcnt   (ddr_burstcnt),
	.ddr_addr       (ddr_addr),
	.ddr_dout       (ddr_dout),
	.ddr_dout_ready (ddr_dout_ready),
	.ddr_rd         (ddr_rd),
	.ddr_din        (ddr_din),
	.ddr_be         (ddr_be),
	.ddr_we         (ddr_we),

	.clk_vid        (clk_vid),
	.ce_pix         (ce_pix),
	.reset          (reset),
	.de             (tim_de),
	.vblank         (tim_vblank),
	.new_frame      (tim_new_frame),
	.new_line       (tim_new_line),
	.field          (tim_field),

	.mode_out       (rd_mode),
	.h_offset_out   (rd_h_offset),
	.v_offset_out   (rd_v_offset),

	.r_out          (vga_r),
	.g_out          (vga_g),
	.b_out          (vga_b),
	.frame_ready    (frame_ready)
);

assign vga_hs        = tim_hs;
assign vga_vs        = tim_vs;
assign vga_de        = tim_de;
assign vga_hblank    = tim_hblank;
assign vga_vblank    = tim_vblank;
assign vga_vcount    = tim_vcount;
assign vga_new_frame = tim_new_frame;
assign vga_field     = tim_field;
assign active        = frame_ready;

endmodule
