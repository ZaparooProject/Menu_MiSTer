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

run_test scanout_tb \
	../sys/mister_magik_vblank_latch.sv ../sys/mister_magik_latch_sys_top_bridge.sv \
	scanout_tb.sv

run_test native_video_timing_tb \
	../rtl/native_video_timing.sv native_video_timing_tb.sv

run_test native_video_reader_tb \
	../rtl/native_video_timing.sv ../rtl/native_video_reader.sv \
	../rtl/native_video_top.sv dcfifo_sim.sv native_video_reader_tb.sv
