// Dedicated video PLL: exact 27.000000 MHz for SD CRT timing.
//
// This cannot come from the main PLL: every output of a PLL divides the
// same VCO, and the smallest common multiple of 100 MHz (clk_sys) and
// 27 MHz is 2700 MHz — outside the Cyclone V's 600-1600 MHz VCO range.
// (That constraint is why stock MiSTer uses 27.027027 MHz: 1000 MHz / 37
// is the closest to 27 MHz a VCO shared with 100 MHz can reach.)
// Standalone, 27 MHz is exact: VCO = 50 MHz x 27 = 1350 MHz, C = 50.

`timescale 1 ps / 1 ps
module pll_video (
		input  wire  refclk,   //  refclk.clk
		input  wire  rst,      //   reset.reset
		output wire  outclk_0, // outclk0.clk
		output wire  locked    //  locked.export
	);

	pll_video_0002 pll_video_inst (
		.refclk   (refclk),   //  refclk.clk
		.rst      (rst),      //   reset.reset
		.outclk_0 (outclk_0), // outclk0.clk
		.locked   (locked)    //  locked.export
	);

endmodule
