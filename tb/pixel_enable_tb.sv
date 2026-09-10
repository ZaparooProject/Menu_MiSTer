`timescale 1ns/1ps
module pixel_enable_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;
    reg [1:0] mode = 0;
    wire ce_pix;
    zaparoo_pixel_enable dut (.*);

    initial begin
        // Both progressive modes, interlace, and the reserved-mode fallback.
        // Assert reset at every divider phase, as PLL lock may disappear mid-frame.
        for (integer m = 0; m < 4; m = m + 1) begin
            for (integer phase = 0; phase < 4; phase = phase + 1) begin
                @(negedge clk); reset = 1; mode = m;
                repeat (5) begin
                    @(posedge clk); #1;
                    assert(ce_pix === 1'b0) else $fatal(1, "pixel enable active during reset");
                end
                @(negedge clk); reset = 0;
                for (integer i = 0; i < 8 + phase; i = i + 1) begin
                    @(posedge clk);
                    if (i == 0)
                        assert(ce_pix === 1'b0) else $fatal(1, "consumer saw stale enable at reset release");
                    #1;
                    assert(ce_pix === ((m == 1) ? (i % 2 == 1) : (i % 4 == 0)))
                        else $fatal(1, "divider cadence/phase changed: mode=%0d cycle=%0d", m, i);
                end
            end
        end
        $display("PASS: pixel enable reset, restart phase, progressive and interlaced cadence");
        $finish;
    end
    initial begin
        #20000; $fatal(1, "pixel enable test timeout");
    end
endmodule
