// Behavioral stand-in for the Altera dcfifo megafunction (showahead mode),
// simulation only. No real CDC modeling — pointers are plain integers.

module dcfifo #(
	parameter intended_device_family = "",
	parameter lpm_numwords           = 1024,
	parameter lpm_showahead          = "ON",
	parameter lpm_type               = "dcfifo",
	parameter lpm_width              = 64,
	parameter lpm_widthu             = 10,
	parameter overflow_checking      = "ON",
	parameter rdsync_delaypipe       = 4,
	parameter underflow_checking     = "ON",
	parameter use_eab                = "ON",
	parameter wrsync_delaypipe       = 4
)(
	input  wire                  aclr,
	input  wire [lpm_width-1:0]  data,
	input  wire                  rdclk,
	input  wire                  rdreq,
	input  wire                  wrclk,
	input  wire                  wrreq,
	output wire [lpm_width-1:0]  q,
	output wire                  rdempty,
	output wire                  wrfull,
	output wire [1:0]            eccstatus,
	output wire                  rdfull,
	output wire [lpm_widthu-1:0] rdusedw,
	output wire                  wrempty,
	output wire [lpm_widthu-1:0] wrusedw
);

reg [lpm_width-1:0] mem [0:lpm_numwords-1];
integer wptr = 0, rptr = 0;
integer peak_used = 0;       // TB-visible; may be reset hierarchically
integer overflow_count = 0;  // writes dropped (overflow_checking semantics)
integer underflow_count = 0;

wire [31:0] used = wptr - rptr;

assign q       = mem[rptr % lpm_numwords];
assign rdempty = (used == 0);
assign wrfull  = (used >= lpm_numwords);
assign eccstatus = 2'b00;
assign rdfull  = wrfull;
assign wrempty = rdempty;
assign rdusedw = used[lpm_widthu-1:0];
assign wrusedw = used[lpm_widthu-1:0];

always @(posedge wrclk or posedge aclr) begin
	if (aclr) wptr <= 0;
	else if (wrreq) begin
		if (wrfull) overflow_count = overflow_count + 1;
		else begin
			mem[wptr % lpm_numwords] <= data;
			wptr <= wptr + 1;
			if (wptr + 1 - rptr > peak_used) peak_used = wptr + 1 - rptr;
		end
	end
end

always @(posedge rdclk or posedge aclr) begin
	if (aclr) rptr <= 0;
	else if (rdreq) begin
		if (rdempty) underflow_count = underflow_count + 1;
		else rptr <= rptr + 1;
	end
end

endmodule
