module counter # (
  parameter pw_counter_module = 5
)(
  input clk, 
  input rst, 
  input [(pw_counter_module-1):0] ip_module, /* number of counts */
  output o_tc /* terminal count */
);

reg [(pw_counter_module-1):0] rp_counter; /* counter */

always @(posedge clk) begin
  if(rst) begin
    rp_counter <= 0;
  end
  else begin
    if(rp_counter < ip_module) rp_counter <= rp_counter + 1;
    else rp_counter <= 0;
  end
end

assign o_tc = (rp_counter == (ip_module - 1)) ? 1'b1 : 1'b0;

endmodule