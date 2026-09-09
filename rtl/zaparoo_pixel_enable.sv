`timescale 1ns/1ps
// Keep the exported pixel enable idle while reset is held or the video PLL
// is unlocked. Restart the divider phase when video becomes available.
module zaparoo_pixel_enable (
    input wire clk,
    input wire reset,
    input wire [1:0] mode,
    output reg ce_pix
);
    reg [1:0] ce_div;
    always @(posedge clk) begin
        if (reset) begin
            ce_div <= 2'd0;
            ce_pix <= 1'b0;
        end
        else begin
            ce_div <= ce_div + 2'd1;
            ce_pix <= (mode == 2'd1) ? ce_div[0] : (ce_div == 2'd0);
        end
    end
endmodule
