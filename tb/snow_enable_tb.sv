// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module snow_enable_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;
    reg osd_status = 0;
    reg snow_allowed = 0;
    wire show_snow;
    zaparoo_snow_enable dut (.*);

    // Two synchronizer stages: an input change is visible after two edges.
    task settle;
        begin
            repeat (2) @(posedge clk);
            #1;
        end
    endtask

    initial begin
        // Reset wins over both sources, so a video restart begins black.
        osd_status = 1; snow_allowed = 1;
        repeat (4) begin
            @(posedge clk); #1;
            assert(show_snow === 1'b0) else $fatal(1, "snow during reset");
        end
        @(negedge clk); reset = 0; osd_status = 0; snow_allowed = 0;
        settle;
        assert(show_snow === 1'b0) else $fatal(1, "idle did not start black");

        // Every combination: either source reveals snow, neither keeps black.
        for (integer i = 0; i < 4; i = i + 1) begin
            @(negedge clk); {osd_status, snow_allowed} = i[1:0];
            @(posedge clk); #1;
            settle;
            assert(show_snow === (osd_status | snow_allowed))
                else $fatal(1, "snow source mismatch: osd=%0d allowed=%0d", osd_status, snow_allowed);
        end

        // No frontend and no OSD (kiosk): snow stays up across an OSD cycle.
        @(negedge clk); osd_status = 0; snow_allowed = 1;
        settle;
        assert(show_snow === 1'b1) else $fatal(1, "no snow without frontend or OSD");
        @(negedge clk); osd_status = 1;
        settle;
        @(negedge clk); osd_status = 0;
        repeat (4) begin
            @(posedge clk); #1;
            assert(show_snow === 1'b1) else $fatal(1, "OSD close dropped allowed snow");
        end

        // A frontend taking the screen returns to black within the sync depth.
        @(negedge clk); snow_allowed = 0;
        settle;
        assert(show_snow === 1'b0) else $fatal(1, "frontend takeover did not restore black");

        // One edge after a change the output still holds: no path skips a stage.
        @(negedge clk); snow_allowed = 1;
        @(posedge clk); #1;
        assert(show_snow === 1'b0) else $fatal(1, "snow bypassed the synchronizer");

        $display("PASS: snow enable reset, OSD and no-frontend sources, takeover black");
        $finish;
    end
    initial begin
        #20000; $fatal(1, "snow enable test timeout");
    end
endmodule
