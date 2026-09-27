// Zaparoo native video DDR reader.
//
// DDR contract v2 (one 64-bit beat at 0x3A000000, read each vblank):
//   word0 [31:0]:  (frame_counter << 2) | active_buffer; 0 = writer stopped
//   word1 [63:32]: [31:16] magic, [15:8] signed h_offset (+ = right)
//   0x5A50 legacy: [7:4] signed v_offset, [3:0] mode
//   0x5A51 extended: [7:2] signed v_offset, [1:0] mode
//   mode: 0 = 352x240p60, 1 = 720x480i60, 2 = 352x288p50 (+v = down)
//   0x3A001000: buffer 0   0x3A180000: buffer 1   (tight stride, width*4 B)
//
// The magic is mandatory, and a block is only painted once the writer has
// been shown to be live. Nothing clears DDR on this core's startup, so a
// previous core's leftovers sit at CTRL_ADDR looking like a control block;
// without both checks the reader latches onto that and scans out garbage
// instead of idle video, permanently. A writer proves itself either by
// starting after the reader has seen no writer (word0 == 0 or no magic), or by
// advancing the counter under a block that was already there at reset. Stale
// DDR does neither. Note this is not a heartbeat: once trusted, a writer may
// idle indefinitely without republishing.
//
// In 480i the app publishes one progressive 720x480 frame; this reader
// fetches source line vcount*2 + field, so no field-splitting on the ARM
// side. 720 px = 360 words exceeds the 8-bit burst counter, so 480i lines
// are fetched as two 180-beat bursts.

module native_video_reader
(
	input  wire        ddr_clk,
	input  wire        ddr_busy,
	output reg   [7:0] ddr_burstcnt,
	output reg  [28:0] ddr_addr,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output reg         ddr_rd,
	output wire [63:0] ddr_din,
	output wire  [7:0] ddr_be,
	output wire        ddr_we,

	input  wire        clk_vid,
	input  wire        ce_pix,
	input  wire        reset,
	input  wire        de,
	input  wire        vblank,
	input  wire        new_frame,
	input  wire        new_line,
	input  wire        field,

	// Quasi-static, ddr_clk domain: caller synchronizes into the video
	// domain; the timing module latches them at the field wrap.
	output reg   [1:0] mode_out,
	output reg signed [7:0] h_offset_out,
	output reg signed [5:0] v_offset_out,

	output reg   [7:0] r_out,
	output reg   [7:0] g_out,
	output reg   [7:0] b_out,
	output wire        frame_ready
);

assign ddr_din = 64'd0;
assign ddr_be  = 8'hFF;
assign ddr_we  = 1'b0;

localparam [28:0] CTRL_ADDR   = 29'h07400000;
localparam [28:0] BUF0_V2     = 29'h07400200;
localparam [28:0] BUF1_V2     = 29'h07430000;
localparam [15:0] MAGIC_V2    = 16'h5A50;
localparam [19:0] TIMEOUT_MAX = 20'hF_FFFF;

reg [1:0] new_frame_sync;
always @(posedge ddr_clk) begin
	if(reset) new_frame_sync <= 2'b0;
		else new_frame_sync <= {new_frame_sync[0], new_frame};
end
wire new_frame_ddr = ~new_frame_sync[1] & new_frame_sync[0];

reg [1:0] new_line_sync;
always @(posedge ddr_clk) begin
	if(reset) new_line_sync <= 2'b0;
		else new_line_sync <= {new_line_sync[0], new_line};
end
wire new_line_ddr = ~new_line_sync[1] & new_line_sync[0];

reg [1:0] vblank_sync;
always @(posedge ddr_clk) begin
	if(reset) vblank_sync <= 2'b0;
		else vblank_sync <= {vblank_sync[0], vblank};
end
wire vblank_ddr = vblank_sync[1];

// Field is stable for a whole field; the reader samples it only while
// scanning, long after the edge.
reg [1:0] field_sync;
always @(posedge ddr_clk) begin
	if(reset) field_sync <= 2'b0;
		else field_sync <= {field_sync[0], field};
end
wire field_ddr = field_sync[1];

reg [1:0] reset_vid_sync;
always @(posedge clk_vid or posedge reset) begin
	if(reset) reset_vid_sync <= 2'b11;
		else reset_vid_sync <= {reset_vid_sync[0], 1'b0};
end
wire reset_vid = reset_vid_sync[1];

reg frame_ready_reg;
reg [1:0] frame_ready_sync;
always @(posedge clk_vid) begin
	if(reset_vid) frame_ready_sync <= 2'b0;
		else frame_ready_sync <= {frame_ready_sync[0], frame_ready_reg};
end
wire frame_ready_vid = frame_ready_sync[1];
assign frame_ready = frame_ready_vid;

localparam [3:0] ST_IDLE         = 4'd0;
localparam [3:0] ST_POLL_CTRL    = 4'd1;
localparam [3:0] ST_WAIT_CTRL    = 4'd2;
localparam [3:0] ST_CHECK_CTRL   = 4'd3;
localparam [3:0] ST_READ_LINE    = 4'd4;
localparam [3:0] ST_WAIT_LINE    = 4'd5;
localparam [3:0] ST_LINE_DONE    = 4'd6;
localparam [3:0] ST_WAIT_DISPLAY = 4'd7;

reg  [3:0]  state;
reg  [31:0] ctrl_word;
reg  [31:0] ctrl_word1;
reg  [29:0] prev_frame_counter;
reg  [28:0] buf_base_addr;
reg  [8:0]  cur_line;
reg  [7:0]  beat_count;
reg         burst_idx;
reg         first_frame_loaded;
// Gates frame_ready. Set when the reader observes no writer (so whatever
// publishes next started while it was watching), and when the counter changes
// under a block that was already present at reset. Never cleared afterwards:
// an idle writer that stops republishing keeps its last frame on screen.
reg         writer_trusted;
reg         preloading;
reg  [19:0] timeout_cnt;
reg         fifo_wr;
reg  [63:0] fifo_wr_data;
wire        fifo_full;

// Per-frame fetch geometry, registered in ST_CHECK_CTRL from the parsed
// control block: line length in 64-bit words, line count, interlace flag.
reg  [8:0]  line_words;
reg  [8:0]  scan_lines;
reg         scan_interlaced;
reg         two_bursts;

wire        extended = (ctrl_word1[31:16] == 16'h5A51);
wire        magic_ok = extended || (ctrl_word1[31:16] == MAGIC_V2);
wire [3:0]  raw_mode = extended ? {2'b00, ctrl_word1[1:0]} : ctrl_word1[3:0];
wire [1:0]  ctrl_mode = (raw_mode > 4'd2) ? 2'd0 : raw_mode[1:0];
wire signed [7:0] ctrl_h = $signed(ctrl_word1[15:8]);
wire signed [3:0] legacy_v = $signed(ctrl_word1[7:4]);
// Preserve legacy clamp semantics while extended writers use wider porches.
wire signed [7:0] legacy_h = (ctrl_h > 8'sd8) ? 8'sd8 : (ctrl_h < -8'sd8) ? -8'sd8 : ctrl_h;

// 480i: source line = displayed line * 2 + field, from one progressive frame.
wire [8:0]  src_line  = scan_interlaced ? ({cur_line[7:0], 1'b0} + {8'd0, field_ddr}) : cur_line;
wire [28:0] line_base = buf_base_addr + src_line * line_words;
wire [7:0]  burst_len = two_bursts ? 8'd180 : line_words[7:0];

reg [3:0] fifo_aclr_cnt;
wire fifo_aclr_ddr_active = (fifo_aclr_cnt != 4'd0);
wire fifo_aclr = reset | fifo_aclr_ddr_active;

always @(posedge ddr_clk) begin
	if(reset) begin
		state              <= ST_IDLE;
		ddr_rd             <= 1'b0;
		ddr_burstcnt       <= 8'd1;
		ddr_addr           <= 29'd0;
		ctrl_word          <= 32'd0;
		ctrl_word1         <= 32'd0;
		prev_frame_counter <= 30'd0;
		buf_base_addr      <= BUF0_V2;
		cur_line           <= 9'd0;
		beat_count         <= 8'd0;
		burst_idx          <= 1'b0;
		first_frame_loaded <= 1'b0;
		writer_trusted     <= 1'b0;
		frame_ready_reg    <= 1'b0;
		preloading         <= 1'b0;
		timeout_cnt        <= 20'd0;
		fifo_wr            <= 1'b0;
		fifo_wr_data       <= 64'd0;
		fifo_aclr_cnt      <= 4'd0;
		mode_out           <= 2'd0;
		h_offset_out       <= 8'sd0;
		v_offset_out       <= 6'sd0;
		line_words         <= 9'd160;
		scan_lines         <= 9'd240;
		scan_interlaced    <= 1'b0;
		two_bursts         <= 1'b0;
	end
	else begin
		fifo_wr <= 1'b0;
		if(fifo_aclr_cnt != 4'd0) fifo_aclr_cnt <= fifo_aclr_cnt - 4'd1;
		if(!ddr_busy) ddr_rd <= 1'b0;

		if(state == ST_WAIT_LINE && ddr_dout_ready) begin
			fifo_wr      <= 1'b1;
			fifo_wr_data <= ddr_dout;
			beat_count   <= beat_count + 8'd1;
			timeout_cnt  <= 20'd0;
		end

		case(state)
			ST_IDLE: begin
				if(new_frame_ddr) state <= ST_POLL_CTRL;
			end

			ST_POLL_CTRL: begin
				if(!ddr_busy) begin
					ddr_addr     <= CTRL_ADDR;
					ddr_burstcnt <= 8'd1;
					ddr_rd       <= 1'b1;
					timeout_cnt  <= 20'd0;
					state        <= ST_WAIT_CTRL;
				end
			end

			ST_WAIT_CTRL: begin
				if(ddr_dout_ready) begin
					ctrl_word   <= ddr_dout[31:0];
					ctrl_word1  <= ddr_dout[63:32];
					timeout_cnt <= 20'd0;
					state       <= ST_CHECK_CTRL;
				end
				else if(timeout_cnt == TIMEOUT_MAX) begin
					// Stale frame_ready would scan a dead buffer forever;
					// drop back to the noise pattern instead.
					frame_ready_reg    <= 1'b0;
					first_frame_loaded <= 1'b0;
					state              <= ST_IDLE;
				end
				else timeout_cnt <= timeout_cnt + 20'd1;
			end

			ST_CHECK_CTRL: begin
				if(ctrl_word == 32'd0 || !magic_ok) begin
					// Writer stopped, never started, or this is not a control
					// block at all: revert to idle video and forget the
					// previous session.
					frame_ready_reg    <= 1'b0;
					first_frame_loaded <= 1'b0;
					// Nothing is publishing right now, so the next block to
					// appear started under observation and can be trusted.
					writer_trusted     <= 1'b1;
					prev_frame_counter <= 30'd0;
					mode_out           <= 2'd0;
					h_offset_out       <= 8'sd0;
					v_offset_out       <= 6'sd0;
					state              <= ST_IDLE;
				end
				else begin
					mode_out     <= ctrl_mode;
					h_offset_out <= extended ? ctrl_h : legacy_h;
					v_offset_out <= extended ? $signed(ctrl_word1[7:2]) :
					                (legacy_v > 4'sd2 ? 6'sd2 : {{2{legacy_v[3]}}, legacy_v});
					line_words   <= (ctrl_mode == 2'd1) ? 9'd360 : 9'd176;
					scan_lines   <= (ctrl_mode == 2'd2) ? 9'd288 : 9'd240;
					scan_interlaced <= (ctrl_mode == 2'd1);
					two_bursts   <= (ctrl_mode == 2'd1);

					if(ctrl_word[31:2] != prev_frame_counter) begin
						prev_frame_counter <= ctrl_word[31:2];
						buf_base_addr      <= ctrl_word[0] ? BUF1_V2 : BUF0_V2;
						cur_line           <= 9'd0;
						burst_idx          <= 1'b0;
						preloading         <= 1'b1;
						fifo_aclr_cnt      <= 4'd8;
						// A counter moving under a block we already fetched is
						// a live writer even if it was there at reset.
						if(first_frame_loaded) begin
							writer_trusted  <= 1'b1;
							frame_ready_reg <= 1'b1;
						end
						state              <= ST_READ_LINE;
					end
					else if(first_frame_loaded) begin
						cur_line      <= 9'd0;
						burst_idx     <= 1'b0;
						preloading    <= 1'b1;
						fifo_aclr_cnt <= 4'd8;
						state         <= ST_READ_LINE;
					end
					else begin
						state <= ST_IDLE;
					end
				end
			end

			ST_READ_LINE: begin
				if(!ddr_busy && !fifo_aclr_ddr_active) begin
					ddr_addr     <= line_base + (burst_idx ? 29'd180 : 29'd0);
					ddr_burstcnt <= burst_len;
					ddr_rd       <= 1'b1;
					beat_count   <= 8'd0;
					timeout_cnt  <= 20'd0;
					state        <= ST_WAIT_LINE;
				end
			end

			ST_WAIT_LINE: begin
				if(beat_count == burst_len) begin
					if(two_bursts && !burst_idx) begin
						burst_idx <= 1'b1;
						state     <= ST_READ_LINE;
					end
					else begin
						burst_idx <= 1'b0;
						state     <= ST_LINE_DONE;
					end
				end
				else if(timeout_cnt == TIMEOUT_MAX) begin
					frame_ready_reg    <= 1'b0;
					first_frame_loaded <= 1'b0;
					state              <= ST_IDLE;
				end
				else if(!ddr_dout_ready) timeout_cnt <= timeout_cnt + 20'd1;
			end

			ST_LINE_DONE: begin
				cur_line <= cur_line + 9'd1;
				if(cur_line == scan_lines - 9'd1) begin
					first_frame_loaded <= 1'b1;
					frame_ready_reg    <= writer_trusted;
					preloading         <= 1'b0;
					state              <= ST_IDLE;
				end
				else if(preloading && cur_line < 9'd1) begin
					state <= ST_READ_LINE;
				end
				else begin
					preloading <= 1'b0;
					state      <= ST_WAIT_DISPLAY;
				end
			end

			ST_WAIT_DISPLAY: begin
				if(cur_line < scan_lines && new_line_ddr && !vblank_ddr) state <= ST_READ_LINE;
			end

			default: state <= ST_IDLE;
		endcase
	end
end

wire [63:0] fifo_rd_data;
wire        fifo_empty;
reg         fifo_rd;

// 1024 words: 480i preloads 2 x 360-word lines (720 words peak); the
// progressive modes peak around 368 words with their 176-word lines.
dcfifo #(
	.intended_device_family ("Cyclone V"),
	.lpm_numwords           (1024),
	.lpm_showahead          ("ON"),
	.lpm_type               ("dcfifo"),
	.lpm_width              (64),
	.lpm_widthu             (10),
	.overflow_checking      ("ON"),
	.rdsync_delaypipe       (4),
	.underflow_checking     ("ON"),
	.use_eab                ("ON"),
	.wrsync_delaypipe       (4)
) line_fifo (
	.aclr     (fifo_aclr),
	.data     (fifo_wr_data),
	.rdclk    (clk_vid),
	.rdreq    (fifo_rd),
	.wrclk    (ddr_clk),
	.wrreq    (fifo_wr),
	.q        (fifo_rd_data),
	.rdempty  (fifo_empty),
	.wrfull   (fifo_full),
	.eccstatus(),
	.rdfull   (),
	.rdusedw  (),
	.wrempty  (),
	.wrusedw  ()
);

reg [63:0] pixel_word;
reg        pixel_high;
reg        pixel_word_valid;

wire [31:0] pixel_low  = pixel_word[31:0];
wire [31:0] pixel_high_word = pixel_word[63:32];

task automatic output_pixel;
	input [31:0] pixel;
	begin
		// linuxfb write path lands as B,G,R,X in DDR on MiSTer; swap here
		// so launcher can keep doing row memcpy with no CPU-side repack.
		r_out <= pixel[23:16];
		g_out <= pixel[15:8];
		b_out <= pixel[7:0];
	end
endtask

always @(posedge clk_vid) begin
	if(reset_vid) begin
		fifo_rd          <= 1'b0;
		r_out            <= 8'd0;
		g_out            <= 8'd0;
		b_out            <= 8'd0;
		pixel_word       <= 64'd0;
		pixel_high       <= 1'b0;
		pixel_word_valid <= 1'b0;
	end
	else begin
		fifo_rd <= 1'b0;

		if(ce_pix) begin
			if(de && frame_ready_vid) begin
				if(pixel_word_valid) begin
					if(pixel_high) begin
						output_pixel(pixel_high_word);
						pixel_word_valid <= 1'b0;
						pixel_high       <= 1'b0;
					end
					else begin
						output_pixel(pixel_low);
						pixel_high <= 1'b1;
					end
				end
				else if(!fifo_empty) begin
					pixel_word       <= fifo_rd_data;
					pixel_word_valid <= 1'b1;
					pixel_high       <= 1'b1;
					fifo_rd          <= 1'b1;
					output_pixel(fifo_rd_data[31:0]);
				end
				else begin
					r_out <= 8'd0;
					g_out <= 8'd0;
					b_out <= 8'd0;
				end
			end
			else if(de) begin
				r_out <= 8'd0;
				g_out <= 8'd0;
				b_out <= 8'd0;
			end
			else begin
				r_out            <= 8'd0;
				g_out            <= 8'd0;
				b_out            <= 8'd0;
				pixel_high       <= 1'b0;
				pixel_word_valid <= 1'b0;
			end
		end
	end
end

endmodule
