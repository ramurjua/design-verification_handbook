module scope_streamer # (
  parameter p_frame_width = 64
)(
  input clk,
  input rst, /* synchronous reset */

  input i_cmd_start, /* 1-cycle pulse: idle -> running, latches i_sample_count_in */
  input i_cmd_abort, /* 1-cycle pulse: force back to idle */

  input [31:0] i_sample_count_in, /* samples to stream this burst */
  input [15:0] i_decimation,      /* sample every N cycles, 0 and 1 both mean "every cycle" */

  input i_tx_ready, /* scope_cmd_if is idle and can accept a new sample to send */
  input [p_frame_width-1:0] i_sample_data,

  output reg o_running,   /* GET_STATUS state bit: 0 = idle, 1 = running */
  output o_sample_valid,  /* 1-cycle pulse: o_sample_data should be sent now */
  output reg [p_frame_width-1:0] o_sample_data,
  output [15:0] o_remaining_count /* samples left in this burst, for GET_STATUS */
);

assign o_remaining_count = r32_remaining[15:0];

/* real sample period is max(configured decimation, however long it takes
   scope_cmd_if to push the previous sample out the UART) — there is no
   real-time throughput guarantee, see docs/protocol.md */
wire w_decim_tick;
wire w_take_sample = o_running && i_tx_ready && w_decim_tick && (r32_remaining != 32'd0);

scope_decimator decim (
  .clk(clk),
  .rst(rst),
  .i_enable(o_running && i_tx_ready),
  .i_decimation(i_decimation),
  .o_tick(w_decim_tick)
);

reg [31:0] r32_remaining;

assign o_sample_valid = w_take_sample;

always @(posedge clk) begin
  if (rst) begin
    o_running      <= 1'b0;
    r32_remaining  <= 32'd0;
    o_sample_data  <= {p_frame_width{1'b0}};
  end
  else if (i_cmd_abort) begin
    o_running <= 1'b0;
  end
  else if (i_cmd_start && !o_running) begin
    o_running     <= (i_sample_count_in != 32'd0);
    r32_remaining <= i_sample_count_in;
  end
  else if (w_take_sample) begin
    o_sample_data <= i_sample_data;
    r32_remaining <= r32_remaining - 32'd1;
    if (r32_remaining == 32'd1) o_running <= 1'b0; /* burst complete, auto-return to idle */
  end
end

endmodule
