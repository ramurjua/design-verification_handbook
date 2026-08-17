module scope_decimator (
  input clk,
  input rst, /* synchronous reset */
  input i_enable,
  input [15:0] i_decimation, /* sample every N cycles, 0 and 1 both mean "every cycle" */
  output o_tick /* 1-cycle pulse, high on the cycle a sample should be taken */
);

reg [15:0] r16_counter;
wire w_terminal = (i_decimation <= 16'd1) || (r16_counter >= (i_decimation - 16'd1));

assign o_tick = i_enable && w_terminal;

always @(posedge clk) begin
  if (rst || !i_enable) r16_counter <= 16'd0;
  else if (w_terminal)  r16_counter <= 16'd0;
  else                  r16_counter <= r16_counter + 16'd1;
end

endmodule
