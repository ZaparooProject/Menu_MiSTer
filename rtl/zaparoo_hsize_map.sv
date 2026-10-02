// Maps the saved analog H-size setting onto the zaparoo_hretime controls.
//
// h_size is the persisted UI value, -8..+2 (reader-clamped): steps of 1/64
// of the nominal pixel period. 0 means unity and turns the retimer off
// entirely (bypass). hretime's scale input is zero-skip (-8..-1 direct,
// 0..+7 mean effective +1..+8), so positive UI values shift down by one.
//
// 480i (mode 1) always bypasses: effective size is forced to zero while the
// saved progressive value is preserved upstream (reader/TOML keep it).
module zaparoo_hsize_map (
    input  wire        [1:0] mode,
    input  wire signed [7:0] h_size,
    output wire              enable,
    output wire signed [3:0] scale
);

assign enable = (h_size != 8'sd0) && (mode != 2'd1);

wire signed [7:0] mapped = h_size[7] ? h_size : h_size - 8'sd1;
assign scale = mapped[3:0];

endmodule
