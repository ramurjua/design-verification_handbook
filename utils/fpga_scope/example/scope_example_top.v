/* Minimal design that integrates scope_top and feeds it self-generated test
   signals, so the whole chain (FPGA -> UART -> backend -> GUI) can be checked
   without any other logic. See ../docs/integration.md.

   ch0  1 bit   square wave, period 40 clocks
   ch1  1 bit   square wave, period 80 clocks
   ch2  4 bits  ramp, +1 every 8 clocks
   ch3  8 bits  triangle, +/-1 every clock
   ch4  8 bits  slow ramp, +1 every 65536 clocks (slow enough for the Stream tab)
   ch5  8 bits  low byte of control 0: what the GUI writes there shows on the plot
   ch6  1 bit   toggles on every write to control 0, also when the value is the same */

module scope_example_top # (
  parameter p_clk_freq_hz     = 100_000_000, /* frequency of clk */
  parameter p_uart_preescaler = 868          /* p_clk_freq_hz / baudrate: 100 MHz / 115200 */
)(
  input clk,
  input i_rst, /* active high */
  input i_uart_rx,  /* from the USB-UART adapter's TXD */
  output o_uart_tx  /* to the USB-UART adapter's RXD */
);

/* synchronise the external reset to clk (the UART input is synchronised inside the scope) */
reg [1:0] r2_rst_sync;

always @(posedge clk) r2_rst_sync <= {r2_rst_sync[0], i_rst};

wire w_rst = r2_rst_sync[1];

/* ------------------------------------------------------------------ */
/* Test signal generators                                              */
/* ------------------------------------------------------------------ */

reg [4:0] r5_square_counter;
reg r_square_fast;
reg r_square_slow;
reg [2:0] r3_ramp_counter;
reg [3:0] r4_ramp;
reg [7:0] r8_triangle;
reg r_triangle_down;
reg [23:0] r24_slow_counter;

/* controls: only control 0 is used here, the other seven ports are left open */
wire [31:0] w32_control0;
wire [7:0] w8_control_update;
reg r_control0_written;

always @(posedge clk) begin
  if (w_rst) r_control0_written <= 1'b0;
  else if (w8_control_update[0]) r_control0_written <= ~r_control0_written;
end

always @(posedge clk) begin
  if (w_rst) begin
    r5_square_counter <= 5'd0;
    r_square_fast     <= 1'b0;
    r_square_slow     <= 1'b0;
    r3_ramp_counter   <= 3'd0;
    r4_ramp           <= 4'd0;
    r8_triangle       <= 8'd0;
    r_triangle_down   <= 1'b0;
    r24_slow_counter  <= 24'd0;
  end
  else begin
    /* squares: the fast one toggles every 20 clocks, the slow one on every falling edge of the fast one */
    if (r5_square_counter == 5'd19) begin
      r5_square_counter <= 5'd0;
      r_square_fast     <= ~r_square_fast;
      if (r_square_fast) r_square_slow <= ~r_square_slow;
    end
    else r5_square_counter <= r5_square_counter + 5'd1;

    /* ramp: wraps from 15 back to 0 */
    r3_ramp_counter <= r3_ramp_counter + 3'd1;
    if (r3_ramp_counter == 3'd7) r4_ramp <= r4_ramp + 4'd1;

    /* triangle: 0 -> 255 -> 0 */
    if (r_triangle_down) begin
      r8_triangle <= r8_triangle - 8'd1;
      if (r8_triangle == 8'd1) r_triangle_down <= 1'b0;
    end
    else begin
      r8_triangle <= r8_triangle + 8'd1;
      if (r8_triangle == 8'd254) r_triangle_down <= 1'b1;
    end

    r24_slow_counter <= r24_slow_counter + 24'd1;
  end
end

/* ------------------------------------------------------------------ */
/* Scope                                                               */
/* ------------------------------------------------------------------ */

scope_top # (
  .p_num_channels(7),
  .p_ch0_width(1),
  .p_ch1_width(1),
  .p_ch2_width(4),
  .p_ch3_width(8),
  .p_ch4_width(8),
  .p_ch5_width(8),
  .p_ch6_width(1),
  .p_buffer_depth_log2(10), /* 1024 samples */
  .p_uart_preescaler(p_uart_preescaler),
  .p_clk_freq_hz(p_clk_freq_hz)
) scope (
  .clk(clk),
  .rst(w_rst),
  .i_ch0({7'd0, r_square_fast}),
  .i_ch1({7'd0, r_square_slow}),
  .i_ch2({4'd0, r4_ramp}),
  .i_ch3(r8_triangle),
  .i_ch4(r24_slow_counter[23:16]),
  .i_ch5(w32_control0[7:0]),
  .i_ch6({7'd0, r_control0_written}),
  .i_ch7(8'd0),
  .i_uart_rx(i_uart_rx),
  .o_uart_tx(o_uart_tx),
  .o_control0(w32_control0),
  .o_control1(),
  .o_control2(),
  .o_control3(),
  .o_control4(),
  .o_control5(),
  .o_control6(),
  .o_control7(),
  .o_control_update(w8_control_update)
);

endmodule
