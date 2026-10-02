#!/bin/sh
# Simulate native video, scanout and bootstrap with Icarus Verilog.
set -e
cd "$(dirname "$0")"

mkdir -p ../test-output/rtl

run_test() {
	top=$1
	shift
	echo "=== $top ==="
	iverilog -g2012 -I ../sys -s "$top" -o "../test-output/rtl/$top.vvp" "$@"
	timeout 600 vvp "../test-output/rtl/$top.vvp"
}

run_test bootstrap_video_tb \
	../sys/mister_magik_bootstrap_black.sv ../rtl/zaparoo_bootstrap_video.sv \
	bootstrap_video_tb.sv

run_test snow_phase_tb ../rtl/zaparoo_snow_phase.sv snow_phase_tb.sv

run_test pixel_enable_tb ../rtl/zaparoo_pixel_enable.sv pixel_enable_tb.sv

run_test scanout_tb \
	../sys/mister_magik_vblank_latch.sv ../sys/mister_magik_latch_sys_top_bridge.sv \
	scanout_tb.sv

run_test native_video_timing_tb \
	../rtl/native_video_timing.sv native_video_timing_tb.sv

run_test native_video_reader_tb \
	../rtl/native_video_timing.sv ../rtl/native_video_reader.sv \
	../rtl/native_video_top.sv dcfifo_sim.sv native_video_reader_tb.sv

# Part 2 (phases 6-9) of the same testbench; the split keeps each run
# inside the 600 s wall clock at the 54 MHz video clock.
echo "=== native_video_reader_tb (part 2) ==="
iverilog -g2012 -I ../sys -DREADER_TB_PART2=1 -s native_video_reader_tb \
	-o ../test-output/rtl/native_video_reader_tb_part2.vvp \
	../rtl/native_video_timing.sv ../rtl/native_video_reader.sv \
	../rtl/native_video_top.sv dcfifo_sim.sv native_video_reader_tb.sv
timeout 600 vvp ../test-output/rtl/native_video_reader_tb_part2.vvp

run_test hsize_map_tb ../rtl/zaparoo_hsize_map.sv hsize_map_tb.sv

run_test hretime_tb ../rtl/zaparoo_hretime.sv hretime_tb.sv

run_test hretime_480i_tb ../rtl/zaparoo_hretime.sv hretime_480i_tb.sv
