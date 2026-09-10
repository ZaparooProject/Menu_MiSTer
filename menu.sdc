# Core-level timing constraints (processed after sys/sys_top.sdc).

# CLK_VIDEO comes from a dedicated PLL (rtl/pll_video.v) and is asynchronous
# to every other clock in the design: all crossings into and out of the video
# domain go through two-flop synchronizers or the line FIFO's dual-clock
# logic (rtl/native_video_reader.sv, rtl/native_video_top.sv). Without this
# group, derive_pll_clocks leaves the 27 MHz output related to the other
# clocks (shared 50 MHz reference, and absent from sys_top.sdc's exclusive
# groups), and the fitter tries to close those CDC paths against a ~1 ns
# edge relationship.
set_clock_groups -asynchronous \
   -group [get_clocks { *|pll_video|pll_video_inst|altera_pll_i|*[*].*|divclk}]
