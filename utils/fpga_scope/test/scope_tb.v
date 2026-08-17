/**** Global timescale ****/
`timescale 10ns/10ns
`define clkcycle 4

module scope_tb();

  `include "../source/scope_defs.vh"

  /**** Fixed test signals ****/
  integer error_counter = 0;
  integer rx_count = 0;

  /**** Clock / reset ****/
  reg clk;
  reg rst;

  initial begin
    clk = 1'b0;
    forever #(`clkcycle/2) clk = ~clk;
  end

  /**** DUT: 2 channels x 1 bit, small buffer, fast baud for simulation ****/
  reg [7:0] r_ch0, r_ch1;
  wire w_dut_tx;
  wire w_host_tx;

  scope_top # (
    .p_num_channels(2),
    .p_ch0_width(1),
    .p_ch1_width(1),
    .p_buffer_depth_log2(4),  /* depth = 16 samples */
    .p_uart_preescaler(4),
    .p_clk_freq_hz(32'd100_000_000)
  ) dut (
    .clk(clk),
    .rst(rst),
    .i_ch0(r_ch0), .i_ch1(r_ch1), .i_ch2(8'd0), .i_ch3(8'd0),
    .i_ch4(8'd0), .i_ch5(8'd0), .i_ch6(8'd0), .i_ch7(8'd0),
    .i_uart_rx(w_host_tx),
    .o_uart_tx(w_dut_tx)
  );

  /**** Host-side UART (mirrors what the Python backend does) ****/
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

  task reset_task;
  begin
    rst <= 1'b1;
    r_host_tx_dv <= 1'b0;
    r_ch0 <= 8'd0;
    r_ch1 <= 8'd0;
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
    @(posedge clk); /* let uart_tx's own state register settle before sampling o_ready again */
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
    if (rx_count < n)
      $error("[ERROR] timed out waiting for %0d response bytes, only got %0d", n, rx_count);
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

  /**** Test flow ****/
  initial begin
    $dumpfile("scope_tb.vcd");
    $dumpvars();

    $display("[INFO] >> Setting initial conditions.");
    reset_task();

    /* ---- CMD_GET_INFO ---- */
    $display("[INFO] >> Test 1: CMD_GET_INFO");
    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_GET_INFO);
    send_byte(8'h00);
    send_byte(8'h00);
    send_byte(SCOPE_CMD_GET_INFO ^ 8'h00 ^ 8'h00); /* chk */

    wait_rx_count(22, 2000);
    check_byte(0, SCOPE_SYNC_DEV, "GET_INFO sync");
    check_byte(1, SCOPE_CMD_GET_INFO, "GET_INFO cmd echo");
    check_byte(2, 8'h00, "GET_INFO len_h");
    check_byte(3, 8'd17, "GET_INFO len_l");
    check_byte(4, SCOPE_PROTOCOL_VERSION, "protocol_version");
    check_byte(5, 8'b0000_0011, "modes_supported");
    check_byte(6, 8'd2, "num_channels");
    check_byte(7, 8'd1, "channel_widths[0]");
    check_byte(8, 8'd1, "channel_widths[1]");
    check_byte(9, 8'd0, "channel_widths[2]");
    check_byte(15, 8'd4, "buffer_depth_log2");
    check_byte(16, 8'd1, "frame_bytes");
    check_byte(17, 8'h05, "clk_freq_hz[31:24]");
    check_byte(18, 8'hF5, "clk_freq_hz[23:16]");
    check_byte(19, 8'hE1, "clk_freq_hz[15:8]");
    check_byte(20, 8'h00, "clk_freq_hz[7:0]");
    $display("[OK] CMD_GET_INFO checked");

    /* ---- CMD_SET_TRIGGER: ch0 rising edge, pre=4, post=4, decim=1 ---- */
    $display("[INFO] >> Test 2: CMD_SET_TRIGGER");
    clear_rx();
    send_set_trigger();
    wait_rx_count(6, 2000);
    check_byte(0, SCOPE_SYNC_DEV, "SET_TRIGGER sync");
    check_byte(1, SCOPE_CMD_SET_TRIGGER, "SET_TRIGGER cmd echo");
    check_byte(4, SCOPE_STATUS_OK, "SET_TRIGGER status");
    $display("[OK] CMD_SET_TRIGGER accepted");

    /* ---- CMD_ARM ---- */
    $display("[INFO] >> Test 3: CMD_ARM + capture");
    r_ch0 <= 8'h00;
    r_ch1 <= 8'h00;
    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_ARM);
    send_byte(8'h00);
    send_byte(8'h00);
    send_byte(SCOPE_CMD_ARM ^ 8'h00 ^ 8'h00);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "ARM status");

    /* pre-trigger: hold ch0 low well past pre_trigger_count so the
       pre-trigger window is fully primed with zeros */
    repeat (8) @(posedge clk);

    /* rising edge -> trigger */
    r_ch0 <= 8'h01;

    /* hold high through the whole post-trigger window and a margin */
    repeat (20) @(posedge clk);

    /* ---- poll CMD_GET_STATUS until done ---- */
    poll_until_done();

    /* ---- CMD_DUMP ---- */
    $display("[INFO] >> Test 4: CMD_DUMP");
    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_DUMP);
    send_byte(8'h00);
    send_byte(8'h00);
    send_byte(SCOPE_CMD_DUMP ^ 8'h00 ^ 8'h00);

    wait_rx_count(13, 5000); /* sync,cmd,lenh,lenl + 8 payload bytes + chk */
    check_byte(0, SCOPE_SYNC_DEV, "DUMP sync");
    check_byte(1, SCOPE_CMD_DUMP, "DUMP cmd echo");
    check_byte(2, 8'h00, "DUMP len_h");
    check_byte(3, 8'd8, "DUMP len_l");
    check_byte(4, 8'd0, "pre-trigger sample 0");
    check_byte(5, 8'd0, "pre-trigger sample 1");
    check_byte(6, 8'd0, "pre-trigger sample 2");
    check_byte(7, 8'd0, "pre-trigger sample 3");
    check_byte(8, 8'd1, "post-trigger sample 0 (trigger sample)");
    check_byte(9, 8'd1, "post-trigger sample 1");
    check_byte(10, 8'd1, "post-trigger sample 2");
    check_byte(11, 8'd1, "post-trigger sample 3");
    $display("[OK] CMD_DUMP payload matches expected [0,0,0,0,1,1,1,1]");

    /* ---- MODE_STREAM: switch mode and stream a short burst ---- */
    $display("[INFO] >> Test 5: CMD_SET_MODE + CMD_STREAM_START");
    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_SET_MODE);
    send_byte(8'h00);
    send_byte(8'h01);
    send_byte(SCOPE_MODE_STREAM);
    send_byte(SCOPE_CMD_SET_MODE ^ 8'h00 ^ 8'h01 ^ SCOPE_MODE_STREAM);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "SET_MODE(stream) status");

    r_ch0 <= 8'h01; /* constant, so every streamed sample should read back as 1 */
    r_ch1 <= 8'h00;

    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_STREAM_START);
    send_byte(8'h00);
    send_byte(8'h04);
    send_byte(8'h00); send_byte(8'h00); send_byte(8'h00); send_byte(8'd5); /* sample_count = 5 */
    send_byte(SCOPE_CMD_STREAM_START ^ 8'h00 ^ 8'h04 ^ 8'h00 ^ 8'h00 ^ 8'h00 ^ 8'd5);

    wait_rx_count(11, 5000); /* 6-byte ack frame + 5 raw sample bytes */
    check_byte(4, SCOPE_STATUS_OK, "STREAM_START status");
    check_byte(6, 8'd1, "stream sample 0");
    check_byte(7, 8'd1, "stream sample 1");
    check_byte(8, 8'd1, "stream sample 2");
    check_byte(9, 8'd1, "stream sample 3");
    check_byte(10, 8'd1, "stream sample 4");
    $display("[OK] CMD_STREAM_START burst matches expected");

    #(`clkcycle*20);

    if (error_counter == 0) $display("[PASS] All checks passed.");
    else $display("[FAIL] %0d check(s) failed.", error_counter);

    $finish();
  end

  task send_set_trigger;
    reg [7:0] chk;
  begin
    chk = SCOPE_CMD_SET_TRIGGER ^ 8'h00 ^ 8'd15;

    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_SET_TRIGGER);
    send_byte(8'h00);
    send_byte(8'd15);

    /* channel_cfg[0]: enable=1, type=edge-rising(10), bitsel=0 -> 8'b1_0_10_0_000 */
    send_byte(8'hA0); chk = chk ^ 8'hA0;
    send_byte(8'h00); chk = chk ^ 8'h00; /* channel_cfg[1..7] unused */
    send_byte(8'h00); chk = chk ^ 8'h00;
    send_byte(8'h00); chk = chk ^ 8'h00;
    send_byte(8'h00); chk = chk ^ 8'h00;
    send_byte(8'h00); chk = chk ^ 8'h00;
    send_byte(8'h00); chk = chk ^ 8'h00;
    send_byte(8'h00); chk = chk ^ 8'h00;
    send_byte(8'h00); chk = chk ^ 8'h00; /* combine_mode = AND */
    send_byte(8'h00); chk = chk ^ 8'h00; /* pre_trigger_count hi */
    send_byte(8'd4);  chk = chk ^ 8'd4;  /* pre_trigger_count lo */
    send_byte(8'h00); chk = chk ^ 8'h00; /* post_trigger_count hi */
    send_byte(8'd4);  chk = chk ^ 8'd4;  /* post_trigger_count lo */
    send_byte(8'h00); chk = chk ^ 8'h00; /* decimation hi */
    send_byte(8'd1);  chk = chk ^ 8'd1;  /* decimation lo */

    send_byte(chk);
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
      send_byte(SCOPE_CMD_GET_STATUS ^ 8'h00 ^ 8'h00);
      wait_rx_count(7, 2000); /* sync,cmd,lenh,lenl,state,fill_h,fill_l,chk = 8, but len=3 -> total 8 */

      if (rx_buf[4] == {6'd0, SCOPE_ST_DONE}) done = 1'b1;

      repeat (5) @(posedge clk);
      waited = waited + 1;
    end
    if (!done) begin
      $error("[ERROR] capture never reached DONE state");
      error_counter = error_counter + 1;
    end
    else $display("[OK] capture reached DONE state");
  end
  endtask

endmodule
