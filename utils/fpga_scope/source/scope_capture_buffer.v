module scope_capture_buffer # (
  parameter p_addr_width  = 10, /* buffer depth = 2^p_addr_width samples */
  parameter p_frame_width = 64  /* bits per sample = sum of configured channel widths */
)(
  input clk,

  input i_wr_en,
  input [p_addr_width-1:0] i_wr_addr,
  input [p_frame_width-1:0] i_wr_data,

  input i_rd_en,
  input [p_addr_width-1:0] i_rd_addr,
  output reg [p_frame_width-1:0] or_rd_data /* registered, 1-cycle read latency (BRAM-style) */
);

localparam lp_depth = (1 << p_addr_width);

/* simple dual-port, single clock: write and read never overlap in time in this
   core (writes only happen while armed/capturing, reads only while dumping),
   but keeping the ports independent lets synthesis infer a plain BRAM here */
reg [p_frame_width-1:0] rp_mem [0:lp_depth-1];

always @(posedge clk) begin
  if (i_wr_en) rp_mem[i_wr_addr] <= i_wr_data;
end

always @(posedge clk) begin
  if (i_rd_en) or_rd_data <= rp_mem[i_rd_addr];
end

endmodule
