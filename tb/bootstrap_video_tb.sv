// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module bootstrap_video_tb;
    reg native_active = 0;
    reg [23:0] native_rgb = 0;
    reg show_snow = 0;
    reg [23:0] snow_rgb = 24'habcdef;
    reg de_in = 0, hs_in = 0, vs_in = 0;
    wire [23:0] rgb_out;
    wire de_out, hs_out, vs_out;
    zaparoo_bootstrap_video dut (.*);
    initial begin
        // A valid native CRT writer must never be covered by bootstrap black.
        // Writer stop returns to black without changing any timing signals.
        for (integer active = 0; active < 2; active = active + 1) begin
            native_active = active[0];
            for (integer timing = 0; timing < 8; timing = timing + 1) begin
                {de_in, hs_in, vs_in} = timing[2:0];
                for (integer color = 0; color < 256; color = color + 1) begin
                    native_rgb = {color[7:0], ~color[7:0], color[7:0]};
                    #1;
                    assert(rgb_out == (native_active ? native_rgb : 24'd0))
                        else $fatal(1, "idle black/native CRT mux mismatch");
                    assert({de_out, hs_out, vs_out} == {de_in, hs_in, vs_in})
                        else $fatal(1, "bootstrap changed timing");
                end
            end
        end
        native_active = 0; #1;
        assert(rgb_out == 0) else $fatal(1, "writer stop did not restore black");
        show_snow = 1; de_in = 1; #1;
        assert(rgb_out == snow_rgb) else $fatal(1, "show_snow did not reveal snow");
        de_in = 0; #1;
        assert(rgb_out == 0) else $fatal(1, "snow painted outside DE");
        native_active = 1; #1;
        assert(rgb_out == native_rgb) else $fatal(1, "snow covered native frontend");
        native_active = 0; show_snow = 0; de_in = 1; #1;
        assert(rgb_out == 0) else $fatal(1, "clearing show_snow did not restore black");
        $display("PASS: black handoff, snow, native CRT priority and timing");
        $finish;
    end
endmodule
