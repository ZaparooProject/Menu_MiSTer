`timescale 1ns/1ps
module snow_noise_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1, ce_pix = 0;
    wire [5:0] noise;
    zaparoo_snow_noise dut (.*);

    localparam integer SAMPLES = 102400;
    integer count [0:63];
    reg [5:0] first [0:15];

    task automatic step;
        @(negedge clk); ce_pix = 1;
        @(posedge clk); #1;
        @(negedge clk); ce_pix = 0;
    endtask

    // Expected share in 1/256 units, from the upstream capture.
    task automatic check_share(input integer value, input integer weight);
        integer expected;
        begin
            expected = SAMPLES * weight / 256;
            assert(count[value] > expected - expected / 10 - 64 &&
                   count[value] < expected + expected / 10 + 64)
                else $fatal(1, "noise %0d: %0d samples, expected about %0d",
                            value, count[value], expected);
        end
    endtask

    initial begin
        for (integer i = 0; i < 64; i = i + 1) count[i] = 0;
        @(posedge clk); #1;
        assert(noise == 0) else $fatal(1, "noise not cleared by reset");
        @(negedge clk); reset = 0;

        repeat (8) @(posedge clk);
        #1 assert(noise == 0) else $fatal(1, "noise advanced without ce_pix");

        for (integer i = 0; i < 16; i = i + 1) begin step; first[i] = noise; end
        @(negedge clk); reset = 1;
        @(negedge clk); reset = 0;
        for (integer i = 0; i < 16; i = i + 1) begin
            step;
            assert(noise == first[i]) else $fatal(1, "sequence differs after reset");
        end

        for (integer i = 0; i < SAMPLES; i = i + 1) begin
            step;
            count[noise] = count[noise] + 1;
        end

        check_share(63, 109);
        check_share(0, 96);
        check_share(16, 26);
        check_share(47, 16);
        check_share(31, 6);
        check_share(15, 3);
        assert(count[63] + count[0] + count[16] + count[47] + count[31] + count[15] == SAMPLES)
            else $fatal(1, "noise produced a value outside the upstream set");

        $display("PASS: snow noise reset, ce_pix gating and upstream distribution");
        $finish;
    end
    initial begin
        #10000000; $fatal(1, "snow noise simulation timeout");
    end
endmodule
