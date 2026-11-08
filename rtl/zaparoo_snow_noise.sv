`timescale 1ns/1ps
// Clocked replacement for upstream's lcell oscillator, whose output depends on
// each fit. Weights (of 256) match a capture of the upstream 20261010 build.
module zaparoo_snow_noise (
    input wire clk,
    input wire reset,
    input wire ce_pix,
    output reg [5:0] noise
);
    localparam [31:0] SEED = 32'h1D872B41;

    reg [31:0] state = SEED;
    wire [31:0] s1 = state ^ (state << 13);
    wire [31:0] s2 = s1 ^ (s1 >> 17);
    wire [31:0] next = s2 ^ (s2 << 5);
    wire [7:0] r = next[31:24];

    initial noise = 0;
    always @(posedge clk) begin
        if (reset) begin
            state <= SEED;
            noise <= 0;
        end else if (ce_pix) begin
            state <= next;
            if      (r < 8'd109) noise <= 6'd63;
            else if (r < 8'd205) noise <= 6'd0;
            else if (r < 8'd231) noise <= 6'd16;
            else if (r < 8'd247) noise <= 6'd47;
            else if (r < 8'd253) noise <= 6'd31;
            else                 noise <= 6'd15;
        end
    end
endmodule
