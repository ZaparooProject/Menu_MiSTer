`timescale 1ns/1ps
// Upstream Menu advances its cosine phase by six once per displayed frame.
// native_video_timing holds new_frame until the next pixel-enable edge.
module zaparoo_snow_phase (
    input wire clk,
    input wire reset,
    input wire ce_pix,
    input wire new_frame,
    input wire [8:0] vcount,
    output wire [9:0] phase
);
    reg [9:0] frame_phase = 0;
    always @(posedge clk) begin
        if (reset) frame_phase <= 0;
        else if (ce_pix && new_frame) frame_phase <= frame_phase + 10'd6;
    end
    assign phase = frame_phase + {vcount[7:0], 2'b00};
endmodule
