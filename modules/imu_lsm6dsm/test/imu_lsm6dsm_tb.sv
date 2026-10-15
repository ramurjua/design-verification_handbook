/**** Global timescale ****/
`timescale 10ns/10ns
`define clkcycle 4

/**** Global definitions ****/
`define _1us 100
`define _10us 1000
`define _100us 10000
`define _1ms 100000
`define _10ms 1000000
`define _100ms 10000000
`define _100ns 10
`define _40ns 4
`define _30ns 3

module imu_lsm6dsm_tb();

  /**** Fixed test signals ****/
  integer error_counter = 0;
  integer sample_count = 0;
  integer id_fails_left = 2; /* wrong WHO_AM_I answers the fake IMU gives before the right one */
  integer id_reads_seen = 0;
  integer absent_txn_count = 0;

  /**** Test signals ****/
  reg clk25;
  reg resetn;

  /**** Clock generation ****/
  initial begin
    clk25 = 1'b0;
    #(`clkcycle/2);
    forever
    #(`clkcycle/2) clk25 = ~clk25;
  end

  /**** DUT <-> fake IMU SPI bus ****/
  wire w_spi_cs_n;
  wire w_spi_sck;
  wire w_spi_mosi;
  wire w_spi_miso;

  wire signed [15:0] w_gyro_x, w_gyro_y, w_gyro_z;
  wire signed [15:0] w_accel_x, w_accel_y, w_accel_z;
  wire w_valid;
  wire w_id_ok;
  wire w_id_error;

  /**** Ticks: one every lp_frame cycles, as a scheduler gives a driver that
        is alone on the bus. The slot is the time the integrator reserves for
        the driver after each tick: the longest transaction (the 104-bit
        burst) must end inside it ****/
  localparam lp_frame = 1000;
  localparam lp_imu_slot = 1000;
  reg r_tick = 1'b0;
  integer tick_div = 0;
  wire w_tick = r_tick;

  always @(posedge clk25) begin
    tick_div <= (!resetn || tick_div >= lp_frame-1) ? 0 : tick_div + 1;
    r_tick <= resetn && (tick_div == lp_frame-1);
  end

  /**** DUT: IMU driver, sped up for simulation (real hardware uses much
        larger reset/retry waits and frame - the FSM logic exercised is identical) ****/
  wire w_overrun;

  imu_lsm6dsm #(
    .p_reset_wait_cycles(20),
    .p_id_retry_wait_cycles(30)
  ) dut (
    .clk(clk25),
    .rst(!resetn),
    .i_tick(w_tick),

    .o_spi_cs_n(w_spi_cs_n),
    .o_spi_sck(w_spi_sck),
    .o_spi_mosi(w_spi_mosi),
    .i_spi_miso(w_spi_miso),

    .os16_gyro_x(w_gyro_x),
    .os16_gyro_y(w_gyro_y),
    .os16_gyro_z(w_gyro_z),
    .os16_accel_x(w_accel_x),
    .os16_accel_y(w_accel_y),
    .os16_accel_z(w_accel_z),
    .or_valid(w_valid),
    .or_id_ok(w_id_ok),
    .or_id_error(w_id_error),
    .or_overrun(w_overrun),
    .o5_debug_state()
  );

  /**** Fake IMU: behavioural model of the LSM6DSM SPI slave port, following
        the datasheet's mode 3 description (section 5.1.2): cs_n frames the
        transaction, sck is stopped high while cs_n is high, bit 0 starts at
        the first sck falling edge after cs_n falls, sdi is captured on
        rising edges and sdo is driven on falling edges from bit 8 of a read
        (released otherwise). Anything else on the bus is reported as an
        error, so a master that is not really in mode 3 fails this test. ****/
  localparam signed [15:0] lp_gyro_x  =  16'sd100;
  localparam signed [15:0] lp_gyro_y  = -16'sd200;
  localparam signed [15:0] lp_gyro_z  =  16'sd300;
  localparam signed [15:0] lp_accel_x =  16'sd1000;
  localparam signed [15:0] lp_accel_y = -16'sd1500;
  localparam signed [15:0] lp_accel_z =  16'sd8192;

  /* OUTX_L_G..OUTZ_H_A (22h-2Dh), one byte per octet, MSb first */
  localparam [95:0] lp_burst_payload = {
    lp_gyro_x[7:0],  lp_gyro_x[15:8],
    lp_gyro_y[7:0],  lp_gyro_y[15:8],
    lp_gyro_z[7:0],  lp_gyro_z[15:8],
    lp_accel_x[7:0], lp_accel_x[15:8],
    lp_accel_y[7:0], lp_accel_y[15:8],
    lp_accel_z[7:0], lp_accel_z[15:8]
  };

  localparam [6:0] lp_addr_who_am_i = 7'h0F;
  localparam [6:0] lp_addr_outx_l_g = 7'h22;

  /* expected {RW,ADDR[6:0],DATA[7:0]} for each write the driver issues, in order (default DUT params) */
  localparam [63:0] lp_exp_writes = {
    16'h1201, /* CTRL3_C <= SW_RESET (0x01) */
    16'h1244, /* CTRL3_C <= BDU|IF_INC (0x44) */
    16'h105C, /* CTRL1_XL <= ODR 208Hz, FS +/-8g (0x5C) */
    16'h1158  /* CTRL2_G <= ODR 208Hz, FS +/-1000dps (0x58) */
  };

  /* a wrong WHO_AM_I answer is 00h, what a silent bus reads through the pull-down */
  function [7:0] imu_reg(input [6:0] addr);
    begin
      if (addr == lp_addr_who_am_i) imu_reg = (id_fails_left > 0) ? 8'h00 : 8'h6A;
      else if (addr >= lp_addr_outx_l_g && addr < lp_addr_outx_l_g + 12)
        imu_reg = lp_burst_payload[95 - 8*(addr - lp_addr_outx_l_g) -: 8];
      else imu_reg = 8'h00;
    end
  endfunction

  reg r_imu_sdo;
  reg r_imu_sdo_en;
  reg r_imu_rw;
  reg [6:0] r_imu_addr;
  reg [7:0] r_imu_wdata;
  reg r_mosi_at_edge;
  integer imu_bits = 0;  /* sck rising edges seen in the current transaction */
  integer imu_fall = 0;  /* sck falling edges seen in the current transaction */
  integer write_count = 0;

  assign w_spi_miso = r_imu_sdo_en ? r_imu_sdo : 1'bz;
  pulldown (w_spi_miso); /* same as the PULLDOWN on the FPGA pin */

  /* mosi as it was just before the current instant: what a slave with a
     real set-up time captures on a clock edge */
  wire #1 w_spi_mosi_dly = w_spi_mosi;

  initial begin
    r_imu_sdo = 1'b0;
    r_imu_sdo_en = 1'b0;
  end

  always @(negedge w_spi_cs_n) if (resetn) begin
    if (w_spi_sck !== 1'b1) begin
      $error("[ERROR]: sck is %b when cs_n falls, mode 3 needs it high", w_spi_sck);
      error_counter = error_counter + 1;
    end
    imu_bits = 0;
    imu_fall = 0;
    r_imu_sdo_en = 1'b0;
  end

  always @(negedge w_spi_sck) if (resetn && !w_spi_cs_n) begin
    imu_fall = imu_fall + 1;
    /* bit n starts at falling edge n+1: the read data goes out from bit 8 */
    if (r_imu_rw && imu_bits >= 8 && imu_fall == imu_bits + 1) begin
      r_imu_sdo = imu_reg(r_imu_addr + (imu_bits - 8)/8) >> (7 - (imu_bits % 8));
      r_imu_sdo_en = 1'b1;
    end
  end

  always @(posedge w_spi_sck) if (resetn && !w_spi_cs_n) begin
    r_mosi_at_edge = w_spi_mosi_dly;
    if (imu_fall != imu_bits + 1) begin
      $error("[ERROR]: sck rising edge %0d without its falling edge first", imu_bits);
      error_counter = error_counter + 1;
    end
    if (imu_bits == 0) r_imu_rw = r_mosi_at_edge;
    else if (imu_bits < 8) r_imu_addr = {r_imu_addr[5:0], r_mosi_at_edge};
    else r_imu_wdata = {r_imu_wdata[6:0], r_mosi_at_edge};
    imu_bits = imu_bits + 1;
    #1;
    if (w_spi_mosi !== r_mosi_at_edge) begin
      $error("[ERROR]: mosi changed on the sck rising edge of bit %0d", imu_bits - 1);
      error_counter = error_counter + 1;
    end
  end

  always @(posedge w_spi_cs_n) if (resetn) begin
    r_imu_sdo_en = 1'b0;
    if (w_spi_sck !== 1'b1) begin
      $error("[ERROR]: sck is %b when cs_n rises, mode 3 stops it high", w_spi_sck);
      error_counter = error_counter + 1;
    end
    if (r_imu_rw && r_imu_addr == lp_addr_who_am_i && imu_bits == 16) begin
      id_reads_seen = id_reads_seen + 1;
      if (id_fails_left > 0) id_fails_left = id_fails_left - 1;
    end
    else if (r_imu_rw && r_imu_addr == lp_addr_outx_l_g && imu_bits == 104) ; /* burst read */
    else if (!r_imu_rw && imu_bits == 16) begin
      if (write_count >= 4 || {1'b0, r_imu_addr, r_imu_wdata} !== lp_exp_writes[63 - 16*write_count -: 16]) begin
        $error("[ERROR]: write %0d mismatch, got %h", write_count, {1'b0, r_imu_addr, r_imu_wdata});
        error_counter = error_counter + 1;
      end
      write_count = write_count + 1;
    end
    else begin
      $error("[ERROR]: unexpected transaction - rw %b addr %h, %0d bits", r_imu_rw, r_imu_addr, imu_bits);
      error_counter = error_counter + 1;
    end
  end

  /**** Second DUT with no IMU on the bus (miso stuck high): must read
        WHO_AM_I p_id_max_attempts times, then flag the error and go quiet ****/
  wire w_absent_cs_n;
  wire w_absent_id_ok;
  wire w_absent_id_error;

  imu_lsm6dsm #(
    .p_reset_wait_cycles(20),
    .p_id_retry_wait_cycles(30),
    .p_id_max_attempts(10)
  ) dut_absent (
    .clk(clk25),
    .rst(!resetn),
    .i_tick(w_tick),
    .o_spi_cs_n(w_absent_cs_n),
    .o_spi_sck(),
    .o_spi_mosi(),
    .i_spi_miso(1'b1),
    .os16_gyro_x(), .os16_gyro_y(), .os16_gyro_z(),
    .os16_accel_x(), .os16_accel_y(), .os16_accel_z(),
    .or_valid(),
    .or_id_ok(w_absent_id_ok),
    .or_id_error(w_absent_id_error),
    .or_overrun(),
    .o5_debug_state()
  );

  always @(negedge w_absent_cs_n) if (resetn) absent_txn_count = absent_txn_count + 1;

  /**** Third DUT with ticks every 100 cycles, shorter than a 16-bit write
        (~130 cycles): a tick lands in the middle of a transaction and must
        flag or_overrun ****/
  reg r_fast_tick = 1'b0;
  integer fast_tick_div = 0;
  wire w_fast_overrun;

  always @(posedge clk25) begin
    fast_tick_div <= (fast_tick_div >= 99) ? 0 : fast_tick_div + 1;
    r_fast_tick <= resetn && (fast_tick_div == 99);
  end

  imu_lsm6dsm #(
    .p_reset_wait_cycles(20),
    .p_id_retry_wait_cycles(30)
  ) dut_fast (
    .clk(clk25),
    .rst(!resetn),
    .i_tick(r_fast_tick),
    .o_spi_cs_n(),
    .o_spi_sck(),
    .o_spi_mosi(),
    .i_spi_miso(1'b0),
    .os16_gyro_x(), .os16_gyro_y(), .os16_gyro_z(),
    .os16_accel_x(), .os16_accel_y(), .os16_accel_z(),
    .or_valid(),
    .or_id_ok(),
    .or_id_error(),
    .or_overrun(w_fast_overrun),
    .o5_debug_state()
  );

  /**** Every transaction starts on a tick and ends inside the slot: cycles
        from the last tick to each cs_n edge ****/
  integer cycles_since_tick = 0;
  integer max_txn_end = 0;
  integer txn_start_count = 0;

  always @(posedge clk25) cycles_since_tick = w_tick ? 0 : cycles_since_tick + 1;

  always @(negedge w_spi_cs_n) if (resetn) begin
    txn_start_count = txn_start_count + 1;
    if (cycles_since_tick > 4) begin
      $error("[ERROR]: transaction %0d started %0d cycles after the last tick", txn_start_count, cycles_since_tick);
      error_counter = error_counter + 1;
    end
  end

  always @(posedge w_spi_cs_n) if (resetn && cycles_since_tick > max_txn_end) max_txn_end = cycles_since_tick;

  /**** Self-checks ****/
  always @(posedge clk25) begin
    if (resetn && w_overrun) begin
      $error("[ERROR]: unexpected or_overrun asserted");
      error_counter = error_counter + 1;
    end

    if (resetn && w_id_error) begin
      $error("[ERROR]: unexpected or_id_error asserted");
      error_counter = error_counter + 1;
    end

    if (resetn && w_valid) begin
      sample_count = sample_count + 1;

      if (!w_id_ok) begin
        $error("[ERROR]: sample %0d arrived but or_id_ok was never asserted", sample_count);
        error_counter = error_counter + 1;
      end

      if (w_gyro_x !== lp_gyro_x || w_gyro_y !== lp_gyro_y || w_gyro_z !== lp_gyro_z ||
          w_accel_x !== lp_accel_x || w_accel_y !== lp_accel_y || w_accel_z !== lp_accel_z) begin
        $error("[ERROR]: sample %0d mismatch - gyro %d/%d/%d accel %d/%d/%d",
               sample_count, w_gyro_x, w_gyro_y, w_gyro_z, w_accel_x, w_accel_y, w_accel_z);
        error_counter = error_counter + 1;
      end
      else $display("[OK]: sample %0d matches canned IMU data", sample_count);
    end
  end

  /**** Test flow ****/
  initial begin

    $dumpfile ("imu_lsm6dsm_tb.vcd");
    $dumpvars();

    $display("[INFO] >> Setting initial conditions.");

    reset_task();

    $display("[INFO] >> Test init");

    fork
      wait (sample_count >= 3 && w_absent_id_error);
      #(40000*`clkcycle);
    join_any
    #(500*`clkcycle); /* long enough to catch any transaction after the driver gave up */

    if (sample_count < 3) begin
      $error("[ERROR]: only %0d sample(s) arrived", sample_count);
      error_counter = error_counter + 1;
    end

    if (write_count !== 4) begin
      $error("[ERROR]: expected 4 register writes (reset + 3 config), saw %0d", write_count);
      error_counter = error_counter + 1;
    end

    if (id_reads_seen !== 3) begin
      $error("[ERROR]: expected 3 WHO_AM_I reads (2 wrong answers + 1 right), saw %0d", id_reads_seen);
      error_counter = error_counter + 1;
    end
    else $display("[OK]: driver retried WHO_AM_I until the IMU answered");

    /* 1 reset write + 10 WHO_AM_I reads */
    if (!w_absent_id_error || w_absent_id_ok || absent_txn_count !== 11) begin
      $error("[ERROR]: absent IMU - id_error %b id_ok %b after %0d transactions, expected error after 11",
             w_absent_id_error, w_absent_id_ok, absent_txn_count);
      error_counter = error_counter + 1;
    end
    else $display("[OK]: absent IMU flagged after 10 WHO_AM_I reads, bus quiet afterwards");

    if (max_txn_end >= lp_imu_slot) begin
      $error("[ERROR]: a transaction ended %0d cycles after its tick, the slot is %0d", max_txn_end, lp_imu_slot);
      error_counter = error_counter + 1;
    end
    else $display("[OK]: %0d transactions, each started on a tick; the longest ended %0d cycles after it (slot %0d)",
                  txn_start_count, max_txn_end, lp_imu_slot);

    if (!w_fast_overrun) begin
      $error("[ERROR]: ticks faster than a transaction did not flag or_overrun");
      error_counter = error_counter + 1;
    end
    else $display("[OK]: ticks faster than a transaction flag or_overrun");

    if (error_counter == 0) $display("[OK] >> All checks passed");
    else $display("[ERROR] >> %0d check(s) failed", error_counter);

    $finish();

  end

  task reset_task;
  begin
    $info("Resetting module.");
    resetn <= 0;

    $info("Release Reset");
    #(20*`clkcycle);
    resetn <= 1;

  end
  endtask

endmodule
