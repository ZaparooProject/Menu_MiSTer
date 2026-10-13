// Dedicated 54.000000 MHz video PLL for the future high-resolution Menu
// re-timer clock.  From the 50 MHz reference it uses a 1350 MHz VCO and a
// divide-by-25 output, so the result is exact and uses integer PLL ratios.
//
// This replaces pll_video (27 MHz) as Menu's video master. The timing engine
// derives its established source-pixel rates with /8 and /4 enables.

`timescale 1 ps / 1 ps
module pll_video54 (
		input  wire  refclk,   //  refclk.clk
		input  wire  rst,      //   reset.reset
		output wire  outclk_0, // outclk0.clk
		output wire  locked    //  locked.export
	);

	pll_video54_0002 pll_video54_inst (
		.refclk   (refclk),   //  refclk.clk
		.rst      (rst),      //   reset.reset
		.outclk_0 (outclk_0), // outclk0.clk
		.locked   (locked)    //  locked.export
	);

endmodule
