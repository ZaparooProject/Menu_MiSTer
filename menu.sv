//============================================================================
//
//  Menu for MiSTer.
//  Copyright (C) 2017-2020 Sorgelig
//
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

assign ADC_BUS  = 'Z;
assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign DDRAM_CLK = clk_sys;
assign CE_PIXEL  = ce_pix;

assign VGA_SL = 0;
// Field number for 480i: ascal (HDMI) keys deinterlacing off this, and the
// analog csync path passes it through. 0 in the progressive modes.
assign VGA_F1 = native_field;
assign VIDEO_ARX = 0;
assign VIDEO_ARY = 0;
assign VGA_SCALER= 0;
assign VGA_DISABLE = 0;

assign AUDIO_MIX = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;

assign LED_DISK = 0;
assign LED_POWER[1]= 1;
assign BUTTONS = 0;

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1; 
assign LED_USER    = FB ? led[0] : act_cnt[26]  ? act_cnt[25:18]  > act_cnt[7:0]  : act_cnt[25:18]  <= act_cnt[7:0];

wire [26:0] act_cnt2 = {~act_cnt[26],act_cnt[25:0]};
assign LED_POWER[0]= FB ? led[2] : act_cnt2[26] ? act_cnt2[25:18] > act_cnt2[7:0] : act_cnt2[25:18] <= act_cnt2[7:0];


`include "build_id.v"
// No video options here: native video mode and centering trims arrive via
// the DDR control block written by the launcher (see rtl/native_video_reader.sv).
localparam CONF_STR = {
	"MENU;UART31250,MIDI;",
	"-;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire [31:0] status;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.forced_scandoubler(forced_scandoubler),
	.status(status),
	.status_menumask(cfg)
);

////////////////////   CLOCKS   ///////////////////
wire locked, clk_sys;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(),         // stock 27.027 MHz output, unused (see pll_video)
	.locked(locked)
);

// Exact 27.000000 MHz video clock from its own PLL: 27 MHz can't share a
// VCO with the 100 MHz clk_sys (lcm = 2700 MHz, above the VCO ceiling).
wire vid_locked;
pll_video pll_video
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(CLK_VIDEO),
	.locked(vid_locked)
);


/////////////////////   SDRAM   ///////////////////
//
// Helper functionality:
//    SDRAM and DDR3 RAM are being cleared while this core is working.
//    some cores behave incorrectly if started with non-clean RAM.

sdram sdr
(
	.*,
	.init(~locked),
	.clk(clk_sys),
	.addr(sdram_addr),
	.wtbt(3),
	.dout(sdram_dout),
	.din(sdram_din),
	.rd(sdram_rd),
	.we(sdram_we),
	.ready(sdram_ready)
);

reg  [26:0] sdram_addr;
wire        sdram_ready;
wire [15:0] sdram_dout;
reg  [15:0] sdram_din;
reg         sdram_we;
reg         sdram_rd;
reg  [15:0] cfg = 0;

always @(posedge clk_sys) begin
	reg [4:0] state = 0;

	sdram_rd <= 0;
	sdram_we <= 0;

	if(RESET) begin
		state <= 0;
		cfg <= 0;
	end
	else begin
		case(state)
			0: if(sdram_ready) begin
					cfg <= 0;
					state      <= state+1'd1;
				end
			1: begin
					sdram_addr <= 'h4000000;
					sdram_din  <= 3128;
					sdram_we   <= 1;
					state      <= state+1'd1;
				end
			2: state <= state+1'd1;
			3: if(sdram_ready) begin
					sdram_addr <= 'h2000000;
					sdram_din  <= 2064;
					sdram_we   <= 1;
					state      <= state+1'd1;
				end
			4: state <= state+1'd1;
			5: if(sdram_ready) begin
					sdram_addr <= 'h0000000;
					sdram_din  <= 1032;
					sdram_we   <= 1;
					state      <= state+1'd1;
				end
			6: state <= state+1'd1;
			7: if(sdram_ready) begin
					sdram_addr <= 'h1000000;
					sdram_din  <= 12345;
					sdram_we   <= 1;
					state      <= state+1'd1;
				end
			8: state <= state+1'd1;
			9: if(sdram_ready) begin
					sdram_addr <= 'h4000000;
					sdram_rd   <= 1;
					state      <= state+1'd1;
				end
			10: state <= state+1'd1;
			11: if(sdram_ready) begin
					cfg[2]     <= (sdram_dout == 3128);
					sdram_addr <= 'h2000000;
					sdram_rd   <= 1;
					state      <= state+1'd1;
				end
			12: state <= state+1'd1;
			13: if(sdram_ready) begin
					cfg[1]     <= (sdram_dout == 2064);
					sdram_addr <= 'h0000000;
					sdram_rd   <= 1;
					state      <= state+1'd1;
				end
			14: state <= state+1'd1;
			15: if(sdram_ready) begin
					cfg[0]     <= (sdram_dout == 1032);
					cfg[15]    <= 1;
					state      <= state+1'd1;
				end
			16: begin
					sdram_we <= 0;
				end
		endcase
	end
end

// DDR clear loop removed: native_video_reader owns DDRAM_* signals.
// The reader polls the launcher's control block once per vblank; until the
// launcher publishes frames it issues a single 64-bit read per frame and the
// core shows the noise pattern.

////////////////////////////  MT32pi  ////////////////////////////////// 

//
// Pin | USB Name | Signal
// ----+----------+--------------
// 0   | D+       | I/O I2C_SDA / RX (midi in)
// 1   | D-       | O   TX (midi out)
// 2   | TX-      | I   I2S_WS (1 == right)
// 3   | GND_d    | I   I2C_SCL
// 4   | RX+      | I   I2S_BCLK
// 5   | RX-      | I   I2S_DAT
// 6   | TX+      | -   none
//

reg [15:0] mt32_i2s_r, mt32_i2s_l;
wire midi_rx;

assign AUDIO_L = mt32_i2s_l;
assign AUDIO_R = mt32_i2s_r;
assign AUDIO_S = 1;

assign USER_OUT[0]   = 1;
assign USER_OUT[1]   = UART_RXD;
assign USER_OUT[6:2] = '1;
assign UART_TXD      = midi_rx;


//
// crossed/straight cable selection
//

generate
genvar i;
for(i = 0; i<2; i++) begin : clk_rate
	wire clk_in = i ? USER_IN[6] : USER_IN[4];
	reg [4:0] cnt;
	always @(posedge CLK_AUDIO) begin : clkr
		reg       clk_sr, clk, old_clk;
		reg [4:0] cnt_tmp;

		clk_sr <= clk_in;
		if (clk_sr == clk_in) clk <= clk_sr;

		if(~&cnt_tmp) cnt_tmp <= cnt_tmp + 1'd1;
		else cnt <= '1;

		old_clk <= clk;
		if(~old_clk & clk) begin
			cnt <= cnt_tmp;
			cnt_tmp <= 0;
		end
	end
end

reg crossed;
always @(posedge CLK_AUDIO) crossed <= (clk_rate[0].cnt <= clk_rate[1].cnt);
endgenerate

wire   i2s_ws   = crossed ? USER_IN[2] : USER_IN[5];
wire   i2s_data = crossed ? USER_IN[5] : USER_IN[2];
wire   i2s_bclk = crossed ? USER_IN[4] : USER_IN[6];
assign midi_rx  = crossed ? USER_IN[6] : USER_IN[4];

always @(posedge CLK_AUDIO) begin : i2s_proc
	reg [15:0] i2s_buf = 0;
	reg  [4:0] i2s_cnt = 0;
	reg        clk_sr;
	reg        i2s_clk = 0;
	reg        old_clk, old_ws;
	reg        i2s_next = 0;

	// Debounce clock
	clk_sr <= i2s_bclk;
	if (clk_sr == i2s_bclk) i2s_clk <= clk_sr;

	// Latch data and ws on rising edge
	old_clk <= i2s_clk;
	if (i2s_clk && ~old_clk) begin

		if (~i2s_cnt[4]) begin
			i2s_cnt <= i2s_cnt + 1'd1;
			i2s_buf[~i2s_cnt[3:0]] <= i2s_data;
		end

		// Word Select will change 1 clock before the new word starts
		old_ws <= i2s_ws;
		if (old_ws != i2s_ws) i2s_next <= 1;
	end

	if (i2s_next) begin
		i2s_next <= 0;
		i2s_cnt <= 0;
		i2s_buf <= 0;

		if (i2s_ws) mt32_i2s_l <= i2s_buf;
		else        mt32_i2s_r <= i2s_buf;
	end
	
	if (RESET) begin
		i2s_buf    <= 0;
		mt32_i2s_l <= 0;
		mt32_i2s_r <= 0;
	end
end

/////////////////////   VIDEO   ///////////////////

localparam lfsr_n = 63;

wire FB  = status[5];
wire [2:0] led = status[8:6];

// Pixel clock: CLK_VIDEO = 27.000 MHz (the universal SD video clock).
// ce_pix /4 = 6.75 MHz gives exactly 15734.27 Hz (NTSC, 429-px line) and
// 15625.00 Hz (PAL, 432-px line); the 480i mode runs /2 = 13.5 MHz with an
// 858-px line for the same 15734.27 Hz. Both the cosine fallback and the FB
// reader use this ce_pix.
wire [1:0] native_mode;
reg [1:0] ce_div;
reg       ce_pix;
always @(posedge CLK_VIDEO) begin
	if (RESET | ~vid_locked) ce_div <= 2'd0;
		else  ce_div <= ce_div + 2'd1;
	ce_pix <= (native_mode == 2'd1) ? ce_div[0] : (ce_div == 2'd0);
end

// Native video timing + DDR reader. Timing outputs (sync, DE, vcount, frame
// edge) are the SINGLE source of truth for VGA scanout in both modes — that's
// what guarantees the CRT sees a clean 15 kHz line rate whether we're
// painting cosine noise or reading a Linux-rendered framebuffer. Mode and
// centering trims come from the launcher's DDR control block, not the OSD.
wire [7:0] native_r;
wire [7:0] native_g;
wire [7:0] native_b;
wire       native_hs;
wire       native_vs;
wire       native_de;
wire [8:0] native_vcount;
wire       native_new_frame;
wire       native_field;
wire       native_active;

native_video_top native_video
(
	.clk_sys        (clk_sys),
	.clk_vid        (CLK_VIDEO),
	.ce_pix         (ce_pix),
	.reset          (RESET | ~vid_locked),

	.ddr_busy       (DDRAM_BUSY),
	.ddr_burstcnt   (DDRAM_BURSTCNT),
	.ddr_addr       (DDRAM_ADDR),
	.ddr_dout       (DDRAM_DOUT),
	.ddr_dout_ready (DDRAM_DOUT_READY),
	.ddr_rd         (DDRAM_RD),
	.ddr_din        (DDRAM_DIN),
	.ddr_be         (DDRAM_BE),
	.ddr_we         (DDRAM_WE),

	.vga_r          (native_r),
	.vga_g          (native_g),
	.vga_b          (native_b),
	.vga_hs         (native_hs),
	.vga_vs         (native_vs),
	.vga_de         (native_de),
	.vga_hblank     (),
	.vga_vblank     (),
	.vga_vcount     (native_vcount),
	.vga_new_frame  (native_new_frame),
	.vga_mode       (native_mode),
	.vga_field      (native_field),
	.active         (native_active)
);

// Cosine + LFSR fallback noise pattern, painted into the active area of the
// shared native timing (352x240 when no launcher is publishing frames). vvc steps once per frame; the LFSR walks every
// pixel; cos LUT is indexed by vvc + vcount so the pattern shifts vertically
// over time. Outside the active area we drive black to keep sync clean.
reg  [9:0] vvc;
reg  [lfsr_n:0] rnd_reg;
wire [lfsr_n:0] rnd;
wire  [5:0] rnd_c = {rnd_reg[0],rnd_reg[1],rnd_reg[2],rnd_reg[2],rnd_reg[2],rnd_reg[2]};

lfsr #(lfsr_n) random(rnd);

always @(posedge CLK_VIDEO) begin
	if (RESET) vvc <= 10'd0;
		else if (native_new_frame) vvc <= vvc + 10'd6;
	if (ce_pix) rnd_reg <= rnd;
end

reg  [7:0] cos_out;
wire [5:0] cos_g = cos_out[7:3] + 6'd32;
cos cos(vvc + {native_vcount, 2'b00}, cos_out);

wire [7:0] comp_v = (cos_g >= rnd_c) ? {cos_g - rnd_c, 2'b00} : 8'd0;

// Default: cosine pattern paints into the native active area. Once the
// launcher publishes frames (valid control block, advancing counter), the
// DDR-read RGB replaces the cosine pattern; it reverts when the writer stops.
// Sync/DE come from the same native timing in both cases — the CRT sees one
// continuous, broadcast-spec signal regardless of which RGB source is selected.
wire use_native = native_active;

assign VGA_DE  = native_de;
assign VGA_HS  = native_hs;
assign VGA_VS  = native_vs;
assign VGA_R   = use_native ? native_r : (native_de ? comp_v : 8'd0);
assign VGA_G   = use_native ? native_g : (native_de ? comp_v : 8'd0);
assign VGA_B   = use_native ? native_b : (native_de ? comp_v : 8'd0);

endmodule
