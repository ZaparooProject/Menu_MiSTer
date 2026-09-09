// Copyright (C) 2026 Nigel Breslaw
// SPDX-License-Identifier: GPL-3.0-or-later
// Derived from tb_mister_magik_sys_top_integration.sv; Zaparoo bus/540p checks.
`timescale 1ns/1ps
module scanout_tb;
    `include "mister_magik_latch_protocol.svh"
    reg clk = 0;
    always #5 clk = ~clk;
    reg vblank = 0, selected = 0, strobe = 0;
    reg [15:0] data_in = 0;
    wire response_valid, apply, accepted, legacy, enabled, filtered, pending;
    wire [15:0] response_data, active_seq, rejects;
    wire [3:0] word_index;
    wire [5:0] format;
    wire [11:0] width, height, hmin, hmax, vmin, vmax;
    wire [31:0] base;
    wire [13:0] stride;
    reg active_enabled = 0;
    reg [31:0] active_base = 0;
    reg [11:0] active_width = 0, active_height = 0;
    reg [13:0] active_stride = 0;
    reg [15:0] reply = 0;
    mister_magik_latch_sys_top_bridge dut (
        .clk_sys(clk), .hdmi_vbl(vblank), .io_uio(selected),
        .io_strobe(strobe), .io_din(data_in),
        .active_lfb_en(active_enabled), .active_lfb_base(active_base),
        .active_lfb_width(active_width), .active_lfb_height(active_height),
        .active_lfb_stride(active_stride), .response_valid(response_valid),
        .response_data(response_data), .apply(apply), .apply_accepted(accepted),
        .legacy_write(legacy), .active_word_index(word_index),
        .route_en(enabled), .route_flt(filtered), .route_fmt(format),
        .route_width(width), .route_height(height), .route_hmin(hmin),
        .route_hmax(hmax), .route_vmin(vmin), .route_vmax(vmax),
        .route_base(base), .route_stride(stride), .pending(pending),
        .pending_seq(), .active_seq(active_seq), .post_count(),
        .flip_count(), .drop_count(), .reject_count(rejects), .active_route_epoch()
    );
    // Mirror sys_top's separate response register and legacy-write priority.
    always @(posedge clk) begin
        if (!selected) reply <= 0;
        else if (strobe) reply <= response_valid ? response_data : 16'd0;
        if (accepted) begin
            active_enabled <= enabled;
            active_base <= base;
            active_width <= width;
            active_height <= height;
            active_stride <= stride;
        end
        if (legacy) begin
            case (word_index)
                0: active_enabled <= data_in[15];
                1: active_base[15:0] <= data_in;
                2: active_base[31:16] <= data_in;
                default: begin end
            endcase
        end
    end
    function automatic [15:0] crc_word(input [15:0] crc, input [15:0] word);
        reg [15:0] next;
        begin
            next = crc;
            for (integer bit_index = 15; bit_index >= 0; bit_index = bit_index - 1)
                next = (next << 1) ^ ((next[15] ^ word[bit_index]) ? 16'h1021 : 16'd0);
            return next;
        end
    endfunction
    task automatic transfer(input [15:0] value, output [15:0] response);
        @(negedge clk); data_in = value; strobe = 1;
        @(posedge clk); #1; response = reply; strobe = 0;
    endtask
    task automatic begin_command(input [7:0] command, input [15:0] magic);
        reg [15:0] response;
        @(negedge clk); selected = 1;
        transfer({8'd0, command}, response);
        assert (response == magic) else $fatal(1, "command %h: %h != %h", command, response, magic);
    endtask
    task automatic end_command;
        @(negedge clk); selected = 0; strobe = 0;
        @(posedge clk); #1;
    endtask
    task automatic post(input bit corrupt, input [15:0] sequence_id);
        reg [15:0] words [0:10];
        reg [15:0] crc, response;
        // 960x540 RGB565 from qualified slot zero into full 1920x1080 HDMI.
        words[0] = 16'h8014;
        words[1] = 16'h0000;
        words[2] = 16'h2300;
        words[3] = 16'd960;
        words[4] = 16'd540;
        words[5] = 16'd0;
        words[6] = 16'd1919;
        words[7] = 16'd0;
        words[8] = 16'd1079;
        words[9] = 16'd1920;
        words[10] = sequence_id;
        crc = crc_word(crc_word(crc_word(16'hffff, 16'h57), 16'd4), 16'd11);
        begin_command(8'h57, MAGIK_FBUF_LATCH_MAGIC);
        for (integer i = 0; i < 11; i = i + 1) begin
            crc = crc_word(crc, words[i]);
            transfer(words[i], response);
        end
        transfer(crc ^ (corrupt ? 16'd1 : 16'd0), response);
        end_command();
    endtask
    initial begin
        reg [15:0] response, receipt [0:10];
        repeat (3) @(posedge clk);
        end_command();
        begin_command(8'h59, MAGIK_FBUF_CAPS_MAGIC);
        transfer(0, response); assert(response == 4) else $fatal;
        transfer(0, response); assert(response == 16'h1ff) else $fatal;
        transfer(0, response); assert(response == 1920) else $fatal;
        transfer(0, response); assert(response == 1080) else $fatal;
        transfer(0, response); assert(response == 3840) else $fatal;
        transfer(0, response); assert(response == 16'h2984) else $fatal;
        end_command();
        post(1, 1);
        assert(!pending && !active_enabled && rejects == 1) else $fatal(1, "bad CRC changed route");
        post(0, 2);
        assert(pending && !active_enabled) else $fatal(1, "route changed before vblank");
        post(0, 3);
        assert(pending && rejects == 2) else $fatal(1, "pending route overwritten");
        begin_command(8'h5b, MAGIK_FBUF_RECEIPT_MAGIC);
        for (integer i = 0; i < 11; i = i + 1) transfer(0, receipt[i]);
        assert(receipt[1] == 3 && receipt[2] == MAGIK_RECEIPT_REJECTED &&
               receipt[4] == 2 && receipt[6] == 2 && receipt[9] == {12'd0, MAGIK_REJECT_PENDING_BUSY})
            else $fatal(1, "receipt lost rejected/accepted distinction");
        end_command();
        @(negedge clk); vblank = 1;
        repeat (5) @(posedge clk); #1;
        assert(active_enabled && active_base == 32'h23000000 && active_width == 960 &&
               active_height == 540 && active_stride == 1920 && active_seq == 2 && !pending &&
               hmax == 1919 && vmax == 1079)
            else $fatal(1, "540p/full HDMI route not applied atomically");
        @(negedge clk); vblank = 0;
        repeat (4) @(posedge clk);
        post(0, 4);
        begin_command(8'h2f, 0);
        @(negedge clk); vblank = 1;
        while (!apply) @(negedge clk);
        data_in = 0; strobe = 1;
        @(posedge clk); #1; strobe = 0;
        assert(!pending && active_seq == 0 && !active_enabled)
            else $fatal(1, "legacy collision failed to reclaim ownership");
        transfer(16'h4444, response); transfer(16'h2222, response);
        end_command();
        assert(active_base == 32'h22224444) else $fatal(1, "legacy framebuffer restore lost");
        $display("PASS: scanout CAPS, CRC, pending/receipts, 540p HDMI, vblank, legacy takeover");
        $finish;
    end
    initial begin
        #20000; $fatal(1, "scanout simulation timeout");
    end
endmodule
