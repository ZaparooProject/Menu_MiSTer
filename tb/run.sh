#!/bin/sh
# Simulate the native video testbenches with Icarus Verilog.
set -e
cd "$(dirname "$0")"

iverilog -g2012 -o native_video_timing_tb.vvp \
	../rtl/native_video_timing.sv native_video_timing_tb.sv
vvp native_video_timing_tb.vvp

iverilog -g2012 -o native_video_reader_tb.vvp \
	../rtl/native_video_timing.sv ../rtl/native_video_reader.sv \
	../rtl/native_video_top.sv dcfifo_sim.sv native_video_reader_tb.sv
vvp native_video_reader_tb.vvp
