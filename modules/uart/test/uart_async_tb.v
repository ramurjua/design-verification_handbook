/* A transmitter and two receivers that share nothing but the serial line:
   one receiver clock is 2 % fast, the other 2 % slow, and bytes are sent at
   random moments (back to back up to long idle gaps). This is the situation
   of a real link (FPGA <-> USB-UART adapter), which uart_tb.v does not
   cover because there both ends run from the same clock and reset. */
`timescale 1ns/1ps

`define n_bytes 300
`define preescaler 16

module uart_async_tb();

  integer error_counter = 0;
  integer i;
  integer n_fast = 0;
  integer n_slow = 0;

  reg clk_tx = 1'b0;
  reg clk_fast = 1'b0;
  reg clk_slow = 1'b0;
  reg rst;

  always #5.0 clk_tx = ~clk_tx;
  always #4.9 clk_fast = ~clk_fast;
  always #5.1 clk_slow = ~clk_slow;

  reg r_dv;
  reg [7:0] r8_data;
  reg [7:0] r8_sent [0:`n_bytes-1];
  wire w_ready;
  wire w_tx;

  uart_tx # (
    .p_preescaler(`preescaler),
    .p_data_buffer(1)
  ) uart_tx (
    .clk(clk_tx),
    .rst(rst),
    .ip_data(r8_data),
    .i_dv(r_dv),
    .o_ready(w_ready),
    .o_tx(w_tx)
  );

  wire [7:0] w8_data_fast, w8_data_slow;
  wire w_dv_fast, w_dv_slow;

  uart_rx # (
    .p_preescaler(`preescaler),
    .p_data_buffer(1)
  ) uart_rx_fast (
    .clk(clk_fast),
    .rst(rst),
    .i_rx(w_tx),
    .orp_data(w8_data_fast),
    .or_dv(w_dv_fast)
  );

  uart_rx # (
    .p_preescaler(`preescaler),
    .p_data_buffer(1)
  ) uart_rx_slow (
    .clk(clk_slow),
    .rst(rst),
    .i_rx(w_tx),
    .orp_data(w8_data_slow),
    .or_dv(w_dv_slow)
  );

  /**** Checkers: every byte must come out of both receivers, in order ****/
  always @(posedge w_dv_fast) begin
    if (w8_data_fast !== r8_sent[n_fast]) begin
      $error("[ERROR]: fast receiver, byte %0d: sent %h - received %h", n_fast, r8_sent[n_fast], w8_data_fast);
      error_counter = error_counter + 1;
    end
    n_fast = n_fast + 1;
  end

  always @(posedge w_dv_slow) begin
    if (w8_data_slow !== r8_sent[n_slow]) begin
      $error("[ERROR]: slow receiver, byte %0d: sent %h - received %h", n_slow, r8_sent[n_slow], w8_data_slow);
      error_counter = error_counter + 1;
    end
    n_slow = n_slow + 1;
  end

  /**** Test flow ****/
  initial begin
    $dumpfile("uart_async_tb.vcd");
    $dumpvars();

    rst <= 1'b1;
    r_dv <= 1'b0;
    repeat (20) @(posedge clk_tx);
    rst <= 1'b0;
    repeat (20) @(posedge clk_tx);

    for (i = 0; i < `n_bytes; i = i + 1) begin
      r8_sent[i] = $urandom();
      r8_data <= r8_sent[i];
      r_dv <= 1'b1;
      @(posedge clk_tx);
      r_dv <= 1'b0;
      @(posedge clk_tx);
      wait (w_ready);
      /* one byte in four goes out back to back, the rest after a random idle gap */
      if ($urandom_range(0, 3) != 0) repeat ($urandom_range(1, 3*`preescaler)) @(posedge clk_tx);
      @(posedge clk_tx);
    end

    repeat (20*`preescaler) @(posedge clk_tx);

    if (n_fast != `n_bytes) begin
      $error("[ERROR]: fast receiver got %0d bytes of %0d", n_fast, `n_bytes);
      error_counter = error_counter + 1;
    end
    if (n_slow != `n_bytes) begin
      $error("[ERROR]: slow receiver got %0d bytes of %0d", n_slow, `n_bytes);
      error_counter = error_counter + 1;
    end

    if (error_counter == 0) $display("[PASS] %0d bytes received correctly by both receivers.", `n_bytes);
    else $display("[FAIL] %0d error(s).", error_counter);

    $finish();
  end

endmodule
