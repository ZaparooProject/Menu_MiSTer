// SPDX-License-Identifier: GPL-3.0-or-later
// Decides when idle video shows snow instead of handoff black. Both inputs
// come from other clock domains and are synchronized here.
//   osd_status:   the stock OSD is up, which always sits on snow.
//   snow_allowed: Main reports that no frontend owns or is about to take the
//                 screen. Clear at reset, so startup stays black until Main
//                 says otherwise, and under a Main that never sets it.
`timescale 1ns/1ps
module zaparoo_snow_enable (
    input wire clk,
    input wire reset,
    input wire osd_status,
    input wire snow_allowed,
    output wire show_snow
);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] osd_sync = 0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] allowed_sync = 0;
    always @(posedge clk) begin
        if (reset) begin
            osd_sync <= 0;
            allowed_sync <= 0;
        end
        else begin
            osd_sync <= {osd_sync[0], osd_status};
            allowed_sync <= {allowed_sync[0], snow_allowed};
        end
    end
    assign show_snow = osd_sync[1] | allowed_sync[1];
endmodule
