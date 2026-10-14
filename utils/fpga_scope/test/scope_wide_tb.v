/**** Global timescale ****/
`timescale 10ns/10ns
`define clkcycle 4

/* scope_top built with p_channel_max_width = 16: 8 channels, seven of 16 bits
   and one of 12, so a sample is 124 bits sent as 16 bytes (the widest frame
   the core can have) with 4 padding bits. scope_tb.v covers the protocol in
   depth at the default width; this one checks what changes with the width:
   GET_INFO, a trigger on a bit above 7, and the byte order of wide samples in
   a dump and a stream burst. */
module scope_wide_tb();

  `include "../source/scope_defs.vh"

  integer error_counter = 0;
  integer rx_count = 0;
  integer k;

  /**** Clock / reset ****/
  reg clk;
  reg rst;

  initial begin
    clk = 1'b0;
    forever #(`clkcycle/2) clk = ~clk;
  end

  /**** DUT ****/
  reg [15:0] r16_ch [0:7];
  wire w_dut_tx;
  wire w_host_tx;

  scope_top # (
    .p_num_channels(8),
    .p_channel_max_width(16),
    .p_ch0_width(16), .p_ch1_width(16), .p_ch2_width(16), .p_ch3_width(16),
    .p_ch4_width(16), .p_ch5_width(16), .p_ch6_width(16), .p_ch7_width(12),
    .p_buffer_depth_log2(4),  /* depth = 16 samples */
    .p_uart_preescaler(4),
    .p_clk_freq_hz(32'd100_000_000)
  ) dut (
    .clk(clk),
    .rst(rst),
    .i_ch0(r16_ch[0]), .i_ch1(r16_ch[1]), .i_ch2(r16_ch[2]), .i_ch3(r16_ch[3]),
    .i_ch4(r16_ch[4]), .i_ch5(r16_ch[5]), .i_ch6(r16_ch[6]), .i_ch7(r16_ch[7]),
    .i_uart_rx(w_host_tx),
    .o_uart_tx(w_dut_tx),
    .o_control0(), .o_control1(), .o_control2(), .o_control3(),
    .o_control4(), .o_control5(), .o_control6(), .o_control7(),
    .o_control_update()
  );

  /**** Host-side UART ****/
  reg r_host_tx_dv;
  reg [7:0] r_host_tx_data;
  wire w_host_tx_ready;

  uart_tx # (
    .p_preescaler(4),
    .p_data_buffer(1)
  ) host_uart_tx (
    .clk(clk),
    .rst(rst),
    .ip_data(r_host_tx_data),
    .i_dv(r_host_tx_dv),
    .o_ready(w_host_tx_ready),
    .o_tx(w_host_tx)
  );

  wire [7:0] w_host_rx_data;
  wire w_host_rx_dv;

  uart_rx # (
    .p_preescaler(4),
    .p_data_buffer(1)
  ) host_uart_rx (
    .clk(clk),
    .rst(rst),
    .i_rx(w_dut_tx),
    .orp_data(w_host_rx_data),
    .or_dv(w_host_rx_dv)
  );

  /**** Response byte capture ****/
  reg [7:0] rx_buf [0:511];

  always @(posedge w_host_rx_dv) begin
    rx_buf[rx_count] <= w_host_rx_data;
    rx_count <= rx_count + 1;
  end

  /**** Tasks ****/

  /* every channel holds a value with both bytes non-zero; ch7's top nibble
     is beyond its 12 bits and must not show up in the samples */
  task reset_task;
  begin
    rst <= 1'b1;
    r_host_tx_dv <= 1'b0;
    for (k = 0; k < 8; k = k + 1) r16_ch[k] <= 16'hA050 + k * 16'h0101;
    r16_ch[5] <= 16'h0FFF; /* bits 11:0 high, bit 12 low: the trigger waits for bit 12 */
    r16_ch[7] <= 16'hFABC;
    repeat (10) @(posedge clk);
    rst <= 1'b0;
    repeat (2) @(posedge clk);
  end
  endtask

  task send_byte(input [7:0] b);
  begin
    wait (w_host_tx_ready);
    @(posedge clk);
    r_host_tx_data <= b;
    r_host_tx_dv   <= 1'b1;
    @(posedge clk);
    r_host_tx_dv <= 1'b0;
    @(posedge clk);
    wait (w_host_tx_ready);
  end
  endtask

  task clear_rx;
  begin
    rx_count <= 0;
  end
  endtask

  task wait_rx_count(input integer n, input integer timeout_cycles);
    integer waited;
  begin
    waited = 0;
    while (rx_count < n && waited < timeout_cycles) begin
      @(posedge clk);
      waited = waited + 1;
    end
    if (rx_count < n) begin
      $error("[ERROR] timed out waiting for %0d response bytes, only got %0d", n, rx_count);
      error_counter = error_counter + 1;
    end
  end
  endtask

  task check_byte(input integer idx, input [7:0] expected, input [127:0] what);
  begin
    if (rx_buf[idx] !== expected) begin
      $error("[ERROR] %0s: rx_buf[%0d] = 0x%02h, expected 0x%02h", what, idx, rx_buf[idx], expected);
      error_counter = error_counter + 1;
    end
  end
  endtask

  /* a command with no payload that answers with one status byte */
  task send_simple(input [7:0] cmd, input [127:0] what);
  begin
    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(cmd);
    send_byte(8'h00);
    send_byte(8'h00);
    send_byte(cmd);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, what);
  end
  endtask

  task send_set_mode(input [7:0] mode);
  begin
    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_SET_MODE);
    send_byte(8'h00);
    send_byte(8'h01);
    send_byte(mode);
    send_byte(SCOPE_CMD_SET_MODE ^ 8'h01 ^ mode);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "SET_MODE status");
  end
  endtask

  /* the sample the channels make with ch5 = `ch5`: channel 0 at the LSB end,
     every channel 16 bits but ch7 (12), 4 zero padding bits on top */
  function [127:0] f_frame(input [15:0] ch5);
  begin
    f_frame = {4'd0, r16_ch[7][11:0], r16_ch[6], ch5, r16_ch[4], r16_ch[3], r16_ch[2], r16_ch[1], r16_ch[0]};
  end
  endfunction

  /* one sample on the wire from rx_buf[first]: 16 bytes, MSB first */
  task check_sample(input integer first, input [127:0] expected, input [127:0] what);
    integer b;
  begin
    for (b = 0; b < 16; b = b + 1)
      if (rx_buf[first + b] !== expected[8*(15-b) +: 8]) begin
        $error("[ERROR] %0s: byte %0d = 0x%02h, expected 0x%02h", what, b, rx_buf[first + b], expected[8*(15-b) +: 8]);
        error_counter = error_counter + 1;
      end
  end
  endtask

  task poll_until_done;
    integer waited;
    reg done;
  begin
    waited = 0;
    done = 1'b0;
    while (!done && waited < 200) begin
      clear_rx();
      send_byte(SCOPE_SYNC_HOST);
      send_byte(SCOPE_CMD_GET_STATUS);
      send_byte(8'h00);
      send_byte(8'h00);
      send_byte(SCOPE_CMD_GET_STATUS);
      wait_rx_count(8, 2000);
      if (rx_buf[4] == {6'd0, SCOPE_ST_DONE}) done = 1'b1;
      repeat (5) @(posedge clk);
      waited = waited + 1;
    end
    if (!done) begin
      $error("[ERROR] capture never reached DONE state");
      error_counter = error_counter + 1;
    end
  end
  endtask

  /**** Test flow ****/
  reg [7:0] chk;
  reg [127:0] r128_before, r128_after;

  initial begin
    $dumpfile("scope_wide_tb.vcd");
    $dumpvars();

    $display("[INFO] >> Setting initial conditions.");
    reset_task();

    /* ---- CMD_GET_INFO ---- */
    $display("[INFO] >> Test 1: CMD_GET_INFO of a 16-bit build");
    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_GET_INFO);
    send_byte(8'h00);
    send_byte(8'h00);
    send_byte(SCOPE_CMD_GET_INFO);
    wait_rx_count(22, 2000);
    check_byte(3, 8'd17, "GET_INFO len_l");
    check_byte(6, 8'd8, "num_channels");
    for (k = 0; k < 7; k = k + 1) check_byte(7 + k, 8'd16, "channel_widths[0..6]");
    check_byte(14, 8'd12, "channel_widths[7]");
    check_byte(16, 8'd16, "frame_bytes");
    $display("[OK] CMD_GET_INFO reports 16-bit channels and 16-byte samples");

    /* ---- CMD_SET_TRIGGER: ch5 rising edge on bit 12, pre=2, post=2 ---- */
    $display("[INFO] >> Test 2: trigger on bit 12 of ch5");
    clear_rx();
    chk = SCOPE_CMD_SET_TRIGGER ^ 8'd15;
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_SET_TRIGGER);
    send_byte(8'h00);
    send_byte(8'd15);
    for (k = 0; k < 8; k = k + 1) begin
      /* enable=1, type=edge-rising(10), bitsel=12 -> 8'b1_0_10_1100 */
      send_byte(k == 5 ? 8'hAC : 8'h00); chk = chk ^ (k == 5 ? 8'hAC : 8'h00);
    end
    send_byte(8'h00);                      /* combine_mode = AND */
    send_byte(8'h00);                      /* pre hi */
    send_byte(8'd2);  chk = chk ^ 8'd2;    /* pre lo */
    send_byte(8'h00);                      /* post hi */
    send_byte(8'd2);  chk = chk ^ 8'd2;    /* post lo */
    send_byte(8'h00);                      /* decimation hi */
    send_byte(8'd1);  chk = chk ^ 8'd1;    /* decimation lo */
    send_byte(chk);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "SET_TRIGGER status");

    send_simple(SCOPE_CMD_ARM, "ARM status");
    repeat (8) @(posedge clk); /* fill the pre-trigger window */

    /* 0x0FFF -> 0x1000: bit 12 rises while bits 11:0 all fall, so a core that
       only looked at the low 3 bits of bit_select (bit 4) would see a falling
       edge here and never trigger */
    r128_before = f_frame(16'h0FFF);
    r16_ch[5] <= 16'h1000;
    @(posedge clk);
    r128_after = f_frame(16'h1000);
    repeat (20) @(posedge clk);
    poll_until_done();
    $display("[OK] the capture triggered on bit 12");

    /* ---- CMD_DUMP: 4 samples x 16 bytes ---- */
    $display("[INFO] >> Test 3: CMD_DUMP of 16-byte samples");
    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_DUMP);
    send_byte(8'h00);
    send_byte(8'h00);
    send_byte(SCOPE_CMD_DUMP);
    wait_rx_count(4 + 64 + 1, 20000);
    check_byte(1, SCOPE_CMD_DUMP, "DUMP cmd echo");
    check_byte(2, 8'h00, "DUMP len_h");
    check_byte(3, 8'd64, "DUMP len_l");
    check_sample(4, r128_before, "pre-trigger sample 0");
    check_sample(20, r128_before, "pre-trigger sample 1");
    check_sample(36, r128_after, "trigger sample");
    check_sample(52, r128_after, "post-trigger sample 1");
    chk = SCOPE_CMD_DUMP ^ 8'd64;
    for (k = 4; k < 68; k = k + 1) chk = chk ^ rx_buf[k];
    check_byte(68, chk, "DUMP chk");
    $display("[OK] CMD_DUMP sends each sample as 16 bytes, MSB first, padding zero");

    /* ---- stream burst of wide samples ---- */
    $display("[INFO] >> Test 4: CMD_STREAM_START with 16-byte samples");
    send_simple(SCOPE_CMD_ABORT, "ABORT status");
    send_set_mode(SCOPE_MODE_STREAM);
    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_STREAM_START);
    send_byte(8'h00);
    send_byte(8'h04);
    send_byte(8'h00); send_byte(8'h00); send_byte(8'h00); send_byte(8'd3); /* sample_count = 3 */
    send_byte(SCOPE_CMD_STREAM_START ^ 8'h04 ^ 8'd3);
    wait_rx_count(6 + 48, 20000);
    check_byte(4, SCOPE_STATUS_OK, "STREAM_START status");
    check_sample(6, r128_after, "stream sample 0");
    check_sample(22, r128_after, "stream sample 1");
    check_sample(38, r128_after, "stream sample 2");
    repeat (800) @(posedge clk);
    if (rx_count != 54) begin
      $error("[ERROR] %0d bytes received, expected 54", rx_count);
      error_counter = error_counter + 1;
    end
    $display("[OK] the stream burst sends 16-byte samples");

    #(`clkcycle*20);

    if (error_counter == 0) $display("[PASS] All checks passed.");
    else $display("[FAIL] %0d check(s) failed.", error_counter);

    $finish();
  end

endmodule
