`timescale 1ns/1ps
module snow_phase_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1, ce_pix = 0, new_frame = 0;
    reg [8:0] vcount = 0;
    wire [9:0] phase;
    zaparoo_snow_phase dut (.*);

    task automatic field_pulse(input integer clocks_per_pixel);
        for (integer i = 0; i < clocks_per_pixel; i = i + 1) begin
            @(negedge clk);
            new_frame = 1;
            ce_pix = (i == clocks_per_pixel - 1);
            @(posedge clk); #1;
        end
        @(negedge clk); new_frame = 0; ce_pix = 0;
    endtask

    initial begin
        @(posedge clk); #1;
        assert(phase == 0) else $fatal(1, "phase not reset");
        @(negedge clk); reset = 0;
        field_pulse(4);
        assert(phase == 6) else $fatal(1, "240p frame advanced more than once");
        field_pulse(2);
        assert(phase == 12) else $fatal(1, "480i field advanced more than once");
        repeat (4) begin @(negedge clk); ce_pix = 1; end
        @(posedge clk); #1;
        assert(phase == 12) else $fatal(1, "phase advanced without frame edge");
        vcount = 9'd1; #1;
        assert(phase == 16) else $fatal(1, "wrong upstream line phase");
        vcount = 9'd256; #1;
        assert(phase == 12) else $fatal(1, "line phase failed to wrap");
        vcount = 0;
        for (integer i = 0; i < 170; i = i + 1) field_pulse(4);
        assert(phase == 8) else $fatal(1, "frame phase failed to wrap");
        $display("PASS: upstream snow cadence, 240p/480i enable and phase wrap");
        $finish;
    end
    initial begin
        #20000; $fatal(1, "snow phase simulation timeout");
    end
endmodule
