/**** Global timescale ****/
`timescale 10ns/10ns
`define clkcycle 4

module scope_tb();

  `include "../source/scope_defs.vh"

  /**** Fixed test signals ****/
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

  /**** DUT: 2 channels x 1 bit, small buffer, fast baud for simulation ****/
  reg [7:0] r_ch0, r_ch1;
  wire w_dut_tx;
  wire w_host_tx;
  wire [31:0] w_control [0:7];
  wire [7:0] w_control_update;

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
    .o_uart_tx(w_dut_tx),
    .o_control0(w_control[0]), .o_control1(w_control[1]), .o_control2(w_control[2]), .o_control3(w_control[3]),
    .o_control4(w_control[4]), .o_control5(w_control[5]), .o_control6(w_control[6]), .o_control7(w_control[7]),
    .o_control_update(w_control_update)
  );

  /**** Controls: what the test last wrote to each one, what it held before
        that, and how many update pulses it has given ****/
  reg [31:0] r_control_expected [0:7];
  reg [31:0] r_control_previous [0:7];
  integer update_count [0:7];
  integer update_expected [0:7];

  initial begin
    for (k = 0; k < 8; k = k + 1) begin
      r_control_expected[k] = 32'd0;
      r_control_previous[k] = 32'd0;
      update_count[k] = 0;
      update_expected[k] = 0;
    end
  end

  genvar gc;
  generate
    for (gc = 0; gc < 8; gc = gc + 1) begin : gen_control_watch
      always @(posedge clk) begin
        if (w_control_update[gc]) update_count[gc] = update_count[gc] + 1;
        /* checked on every clock, not only after a command: a control must go
           from the old value to the new one in a single step, and never move
           when nothing wrote it */
        if (!rst && w_control[gc] !== r_control_expected[gc] && w_control[gc] !== r_control_previous[gc]) begin
          $error("[ERROR] control %0d holds 0x%08h, neither the old value nor the one written", gc, w_control[gc]);
          error_counter = error_counter + 1;
        end
      end
    end
  endgenerate

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

  /**** Optional free-running square wave on ch0 (period 4 cycles) ****/
  reg r_ch0_free_run = 1'b0;
  reg [1:0] r2_free_run_counter = 2'd0;

  always @(posedge clk) begin
    r2_free_run_counter <= r2_free_run_counter + 2'd1;
    if (r_ch0_free_run) r_ch0 <= {7'd0, r2_free_run_counter[1]};
  end

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
    check_byte(4, 8'h02, "protocol_version");
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
    send_set_trigger(8'd4, 8'd4);
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

    /* CMD_SET_MODE is only accepted while idle (docs/protocol.md) - the
       CMD_DUMP above leaves scope_ctrl parked in ST_DONE, not ST_IDLE, so
       an explicit CMD_ABORT is required first to return there. */
    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_ABORT);
    send_byte(8'h00);
    send_byte(8'h00);
    send_byte(SCOPE_CMD_ABORT ^ 8'h00 ^ 8'h00);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "ABORT status");

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

    /* ---- pre-trigger holdoff: a trigger that arrives before the
       pre-trigger window has filled must be ignored, otherwise the start
       of the dump is whatever the buffer held before ---- */
    $display("[INFO] >> Test 6: trigger arriving before the pre-trigger window is full");
    #(`clkcycle*400); /* let the burst's last byte leave the wire */

    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_SET_MODE);
    send_byte(8'h00);
    send_byte(8'h01);
    send_byte(SCOPE_MODE_SCOPE);
    send_byte(SCOPE_CMD_SET_MODE ^ 8'h00 ^ 8'h01 ^ SCOPE_MODE_SCOPE);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "SET_MODE(scope) status");

    clear_rx();
    send_set_trigger(8'd12, 8'd4);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "SET_TRIGGER status");

    r_ch0_free_run <= 1'b1; /* rising edge every 4 cycles: the first one comes long before 12 samples are in */
    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_ARM);
    send_byte(8'h00);
    send_byte(8'h00);
    send_byte(SCOPE_CMD_ARM ^ 8'h00 ^ 8'h00);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "ARM status");

    poll_until_done();
    check_byte(5, 8'd0, "fill_count hi");
    check_byte(6, 8'd16, "fill_count lo");
    r_ch0_free_run <= 1'b0;
    $display("[OK] capture waited for the pre-trigger window");

    /* ---- controls: the core is still in DONE from Test 6, which is as
       good a state as any, a control write does not depend on it ---- */
    $display("[INFO] >> Test 7: CMD_CONTROL_WRITE / CMD_CONTROL_READ");
    check_controls("after reset, before any write");

    clear_rx();
    send_control_write(8'd3, 32'hDEADBEEF);
    wait_rx_count(6, 2000);
    check_byte(0, SCOPE_SYNC_DEV, "CONTROL_WRITE sync");
    check_byte(1, SCOPE_CMD_CONTROL_WRITE, "CONTROL_WRITE cmd echo");
    check_byte(3, 8'd1, "CONTROL_WRITE len_l");
    check_byte(4, SCOPE_STATUS_OK, "CONTROL_WRITE status");
    check_byte(5, SCOPE_CMD_CONTROL_WRITE ^ 8'd1 ^ SCOPE_STATUS_OK, "CONTROL_WRITE chk");
    check_controls("control 3 written");

    clear_rx();
    send_control_read(8'd3);
    wait_rx_count(10, 2000);
    check_byte(0, SCOPE_SYNC_DEV, "CONTROL_READ sync");
    check_byte(1, SCOPE_CMD_CONTROL_READ, "CONTROL_READ cmd echo");
    check_byte(2, 8'h00, "CONTROL_READ len_h");
    check_byte(3, 8'd5, "CONTROL_READ len_l");
    check_byte(4, 8'd3, "CONTROL_READ index");
    check_byte(5, 8'hDE, "CONTROL_READ value[31:24]");
    check_byte(6, 8'hAD, "CONTROL_READ value[23:16]");
    check_byte(7, 8'hBE, "CONTROL_READ value[15:8]");
    check_byte(8, 8'hEF, "CONTROL_READ value[7:0]");
    check_byte(9, SCOPE_CMD_CONTROL_READ ^ 8'd5 ^ 8'd3 ^ 8'hDE ^ 8'hAD ^ 8'hBE ^ 8'hEF, "CONTROL_READ chk");

    clear_rx();
    send_control_read(8'd5); /* one nobody wrote */
    wait_rx_count(10, 2000);
    check_byte(4, 8'd5, "CONTROL_READ index of an unwritten control");
    check_byte(5, 8'h00, "unwritten control [31:24]");
    check_byte(8, 8'h00, "unwritten control [7:0]");
    $display("[OK] a control is written and read back");

    /* the first and the last control, and the same value twice: a button
       pressed again gives a second pulse although the value does not change */
    clear_rx();
    send_control_write(8'd0, 32'd1);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "CONTROL_WRITE(0) status");
    clear_rx();
    send_control_write(8'd7, 32'hFFFFFFFF);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "CONTROL_WRITE(7) status");
    check_controls("controls 0 and 7 written");
    clear_rx();
    send_control_write(8'd0, 32'd1);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "CONTROL_WRITE(0) again status");
    check_controls("control 0 written again with the same value");
    if (update_count[0] != 2) begin
      $error("[ERROR] two writes to control 0 gave %0d update pulses", update_count[0]);
      error_counter = error_counter + 1;
    end
    clear_rx();
    send_control_write(8'd3, 32'h00000000);
    wait_rx_count(6, 2000);
    check_controls("control 3 back to zero");
    $display("[OK] every write gives one update pulse, on its own control only");

    /* ---- writes that must not get through ---- */
    $display("[INFO] >> Test 8: control writes that are refused");
    clear_rx();
    send_raw_control_write(8'd8, 32'h11111111, 8'd5, 8'h00); /* there is no control 8 */
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_ERROR, "CONTROL_WRITE(8) status");
    check_controls("write to a control that does not exist");

    clear_rx();
    send_raw_control_write(8'd1, 32'h22222222, 8'd4, 8'h00); /* one payload byte short */
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_ERROR, "short CONTROL_WRITE status");
    check_controls("write with a short payload");

    clear_rx();
    send_raw_control_write(8'd1, 32'h33333333, 8'd5, 8'h01); /* one bit wrong in the checksum */
    expect_silence("CONTROL_WRITE with a bad checksum");
    check_controls("write with a bad checksum");

    clear_rx();
    send_control_read(8'd8);
    expect_silence("CONTROL_READ of a control that does not exist");
    $display("[OK] bad index, short payload and bad checksum change nothing");

    /* ---- a write while a capture is waiting for its trigger ---- */
    $display("[INFO] >> Test 9: control write during a capture");
    r_ch0 <= 8'h00;
    send_simple(SCOPE_CMD_ABORT, "ABORT");
    clear_rx();
    send_set_trigger(8'd4, 8'd4);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "SET_TRIGGER status");
    send_simple(SCOPE_CMD_ARM, "ARM");

    clear_rx();
    send_control_write(8'd1, 32'h000000A5);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "CONTROL_WRITE while armed status");
    check_controls("control 1 written while armed");

    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_GET_STATUS);
    send_byte(8'h00);
    send_byte(8'h00);
    send_byte(SCOPE_CMD_GET_STATUS);
    wait_rx_count(8, 2000);
    check_byte(4, {6'd0, SCOPE_ST_ARMED}, "still armed after the control write");

    r_ch0 <= 8'h01;
    repeat (20) @(posedge clk);
    poll_until_done();
    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_DUMP);
    send_byte(8'h00);
    send_byte(8'h00);
    send_byte(SCOPE_CMD_DUMP);
    wait_rx_count(13, 5000);
    check_byte(7, 8'd0, "last pre-trigger sample");
    check_byte(8, 8'd1, "trigger sample");
    check_byte(11, 8'd1, "last post-trigger sample");
    $display("[OK] the capture is not disturbed by a control write");

    /* ---- during a stream burst the core only listens for CMD_ABORT, so
       a write is dropped without a response (docs/protocol.md) ---- */
    $display("[INFO] >> Test 10: control write during a stream burst");
    send_simple(SCOPE_CMD_ABORT, "ABORT");
    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_SET_MODE);
    send_byte(8'h00);
    send_byte(8'h01);
    send_byte(SCOPE_MODE_STREAM);
    send_byte(SCOPE_CMD_SET_MODE ^ 8'h00 ^ 8'h01 ^ SCOPE_MODE_STREAM);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "SET_MODE(stream) status");

    clear_rx();
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_STREAM_START);
    send_byte(8'h00);
    send_byte(8'h04);
    send_byte(8'h00); send_byte(8'h00); send_byte(8'h00); send_byte(8'd60);
    send_byte(SCOPE_CMD_STREAM_START ^ 8'h04 ^ 8'd60);
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "STREAM_START status");

    send_raw_control_write(8'd2, 32'h00001234, 8'd5, 8'h00); /* lands in the middle of the burst */
    if (rx_count >= 66) begin
      $error("[ERROR] the burst was over before the control write was sent: this test checked nothing");
      error_counter = error_counter + 1;
    end
    wait_rx_count(66, 20000); /* 6-byte ack + 60 raw sample bytes */
    repeat (800) @(posedge clk);
    if (rx_count != 66) begin
      $error("[ERROR] %0d bytes received, expected the 66 of the burst and no reply to the write", rx_count);
      error_counter = error_counter + 1;
    end
    check_controls("write sent during a stream burst");

    clear_rx();
    send_control_write(8'd2, 32'h00001234); /* the same write once the burst is over */
    wait_rx_count(6, 2000);
    check_byte(4, SCOPE_STATUS_OK, "CONTROL_WRITE after the burst status");
    check_controls("control 2 written after the burst");
    $display("[OK] a write during a burst is dropped, the next one is taken");

    /* ---- reset ---- */
    $display("[INFO] >> Test 11: reset clears the controls");
    for (k = 0; k < 8; k = k + 1) begin
      r_control_previous[k] = r_control_expected[k];
      r_control_expected[k] = 32'd0;
    end
    reset_task();
    check_controls("after reset");
    $display("[OK] controls are zero after reset");

    #(`clkcycle*20);

    if (error_counter == 0) $display("[PASS] All checks passed.");
    else $display("[FAIL] %0d check(s) failed.", error_counter);

    $finish();
  end

  task send_set_trigger(input [7:0] pre, input [7:0] post);
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
    send_byte(pre);   chk = chk ^ pre;   /* pre_trigger_count lo */
    send_byte(8'h00); chk = chk ^ 8'h00; /* post_trigger_count hi */
    send_byte(post);  chk = chk ^ post;  /* post_trigger_count lo */
    send_byte(8'h00); chk = chk ^ 8'h00; /* decimation hi */
    send_byte(8'd1);  chk = chk ^ 8'd1;  /* decimation lo */

    send_byte(chk);
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

  /* CMD_CONTROL_WRITE as it goes on the wire, with `len` payload bytes
     (5 is the right number) and `chk_error` XORed into the checksum */
  task send_raw_control_write(input [7:0] idx, input [31:0] value, input [7:0] len, input [7:0] chk_error);
    reg [7:0] chk;
  begin
    chk = SCOPE_CMD_CONTROL_WRITE ^ len ^ idx;
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_CONTROL_WRITE);
    send_byte(8'h00);
    send_byte(len);
    send_byte(idx);
    if (len > 8'd1) begin send_byte(value[31:24]); chk = chk ^ value[31:24]; end
    if (len > 8'd2) begin send_byte(value[23:16]); chk = chk ^ value[23:16]; end
    if (len > 8'd3) begin send_byte(value[15:8]);  chk = chk ^ value[15:8];  end
    if (len > 8'd4) begin send_byte(value[7:0]);   chk = chk ^ value[7:0];   end
    send_byte(chk ^ chk_error);
  end
  endtask

  /* a well-formed write, which the test expects to be taken: from here on
     the control may hold its old value or the new one, nothing else, and
     must end up with one more update pulse */
  task send_control_write(input [7:0] idx, input [31:0] value);
  begin
    r_control_previous[idx] = r_control_expected[idx];
    r_control_expected[idx] = value;
    update_expected[idx] = update_expected[idx] + 1;
    send_raw_control_write(idx, value, 8'd5, 8'h00);
  end
  endtask

  task send_control_read(input [7:0] idx);
  begin
    send_byte(SCOPE_SYNC_HOST);
    send_byte(SCOPE_CMD_CONTROL_READ);
    send_byte(8'h00);
    send_byte(8'h01);
    send_byte(idx);
    send_byte(SCOPE_CMD_CONTROL_READ ^ 8'h01 ^ idx);
  end
  endtask

  /* every control holds what the test last wrote to it, and has pulsed once per accepted write */
  task check_controls(input [383:0] what);
    integer c;
  begin
    for (c = 0; c < 8; c = c + 1) begin
      if (w_control[c] !== r_control_expected[c]) begin
        $error("[ERROR] %0s: control %0d = 0x%08h, expected 0x%08h", what, c, w_control[c], r_control_expected[c]);
        error_counter = error_counter + 1;
      end
      if (update_count[c] != update_expected[c]) begin
        $error("[ERROR] %0s: control %0d gave %0d update pulses, expected %0d", what, c, update_count[c], update_expected[c]);
        error_counter = error_counter + 1;
      end
      r_control_previous[c] = r_control_expected[c]; /* settled: only the next write may move it */
    end
  end
  endtask

  /* nothing comes back for a frame the core must ignore */
  task expect_silence(input [383:0] what);
  begin
    repeat (800) @(posedge clk); /* a reply would be complete in under 300 */
    if (rx_count != 0) begin
      $error("[ERROR] %0s: got %0d response bytes, expected none", what, rx_count);
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
      send_byte(SCOPE_CMD_GET_STATUS ^ 8'h00 ^ 8'h00);
      wait_rx_count(8, 2000); /* sync,cmd,lenh,lenl,state,fill_h,fill_l,chk = 8, but len=3 -> total 8 */

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
