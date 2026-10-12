// SPDX-License-Identifier: GPL-3.0-or-later
// Native CRT frames take priority; idle is black unless show_snow is set
// (see zaparoo_snow_enable).
`timescale 1ns/1ps
module zaparoo_bootstrap_video (
    input wire native_active,
    input wire [23:0] native_rgb,
    input wire show_snow,
    input wire [23:0] snow_rgb,
    input wire de_in, hs_in, vs_in,
    output wire [23:0] rgb_out,
    output wire de_out, hs_out, vs_out
);
    wire [23:0] black_rgb;
    mister_magik_bootstrap_black black (
        .rgb_in(native_rgb), .de_in(de_in), .hs_in(hs_in), .vs_in(vs_in),
        .rgb_out(black_rgb), .de_out(de_out), .hs_out(hs_out), .vs_out(vs_out)
    );
    assign rgb_out = native_active ? native_rgb :
        (show_snow && de_in) ? snow_rgb : black_rgb;
endmodule
