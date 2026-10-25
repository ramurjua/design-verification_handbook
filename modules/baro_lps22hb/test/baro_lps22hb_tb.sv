/**** Global timescale ****/
`timescale 10ns/10ns
`define clkcycle 4

module baro_lps22hb_tb();

  /**** Fixed test signals ****/
  integer error_counter = 0;
  integer sample_count = 0;
  integer id_fails_left = 2; /* wrong WHO_AM_I answers the fake barometer gives before the right one */
  integer id_reads_seen = 0;
  integer absent_txn_count = 0;
  integer burst_count = 0;    /* burst reads seen by the fake barometer */
  integer new_data_count = 0; /* of those, the ones that found a new sample (P_DA = 1) */

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

  /**** DUT <-> fake barometer SPI bus ****/
  wire w_spi_cs_n;
  wire w_spi_sck;
  wire w_spi_mosi;
  wire w_spi_miso;

  wire signed [23:0] w_pressure;
  wire signed [15:0] w_temperature;
  wire w_valid;
  wire w_id_ok;
  wire w_id_error;

  /**** Ticks: one every lp_frame cycles, as a scheduler gives a driver that
        is alone on the bus. The slot is the time the integrator reserves for
        the driver after each tick (600 in the project it comes from, where
        it shares the bus with an IMU): the longest transaction (the 56-bit
        burst) must end inside it ****/
  localparam lp_frame = 1000;
  localparam lp_baro_slot = 600;
  reg r_tick = 1'b0;
  integer tick_div = 0;
  wire w_tick = r_tick;

  always @(posedge clk25) begin
    tick_div <= (!resetn || tick_div >= lp_frame-1) ? 0 : tick_div + 1;
    r_tick <= resetn && (tick_div == lp_frame-1);
  end

  /**** DUT: barometer driver, sped up for simulation (real hardware uses
        much larger reset/retry waits and frame - the FSM logic exercised is identical) ****/
  wire w_overrun;

  baro_lps22hb #(
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

    .os24_pressure(w_pressure),
    .os16_temperature(w_temperature),
    .or_valid(w_valid),
    .or_id_ok(w_id_ok),
    .or_id_error(w_id_error),
    .or_overrun(w_overrun),
    .o4_debug_state()
  );

  /**** Fake barometer: behavioural model of the LPS22HB SPI slave port,
        following the datasheet (section 7.3): cs_n frames the transaction,
        sck is stopped high while cs_n is high, bit 0 starts at the first sck
        falling edge after cs_n falls, sdi is captured on rising edges and sdo
        is driven on falling edges from bit 8 of a read (released otherwise).
        Anything else on the bus is reported as an error.
        Data: every burst read returns a different pressure and temperature
        (base + burst number), and only every other burst has a new sample
        (STATUS.P_DA), so the driver must drop the others. ****/
  localparam signed [23:0] lp_pressure_base    = 24'sd4150272; /* 1013.25 hPa */
  localparam signed [15:0] lp_temperature_base = -16'sd1234;   /* -12.34 degC: checks the sign */

  localparam [6:0] lp_addr_who_am_i = 7'h0F;
  localparam [6:0] lp_addr_status   = 7'h27;

  /* expected {RW,ADDR[6:0],DATA[7:0]} for each write the driver issues, in order (default DUT params) */
  localparam [47:0] lp_exp_writes = {
    16'h1114, /* CTRL_REG2 <= IF_ADD_INC|SWRESET (0x14) */
    16'h1118, /* CTRL_REG2 <= IF_ADD_INC|I2C_DIS (0x18) */
    16'h103A  /* CTRL_REG1 <= ODR 25 Hz, EN_LPFP, ODR/9, BDU (0x3A) */
  };

  function signed [23:0] burst_pressure(input integer n);
    burst_pressure = lp_pressure_base + n;
  endfunction
  function signed [15:0] burst_temperature(input integer n);
    burst_temperature = lp_temperature_base + n;
  endfunction
  function burst_new_data(input integer n);
    burst_new_data = (n % 2) == 1;
  endfunction

  /* a wrong WHO_AM_I answer is 00h, what a silent bus reads through the pull-down */
  function [7:0] baro_reg(input [6:0] addr);
    reg signed [23:0] p;
    reg signed [15:0] t;
    begin
      p = burst_pressure(burst_count);
      t = burst_temperature(burst_count);
      case (addr)
        lp_addr_who_am_i: baro_reg = (id_fails_left > 0) ? 8'h00 : 8'hB1;
        7'h27: baro_reg = burst_new_data(burst_count) ? 8'h03 : 8'h00; /* STATUS: T_DA, P_DA */
        7'h28: baro_reg = p[7:0];
        7'h29: baro_reg = p[15:8];
        7'h2A: baro_reg = p[23:16];
        7'h2B: baro_reg = t[7:0];
        7'h2C: baro_reg = t[15:8];
        default: baro_reg = 8'h00;
      endcase
    end
  endfunction

  reg r_baro_sdo;
  reg r_baro_sdo_en;
  reg r_baro_rw;
  reg [6:0] r_baro_addr;
  reg [7:0] r_baro_wdata;
  reg r_mosi_at_edge;
  integer baro_bits = 0;  /* sck rising edges seen in the current transaction */
  integer baro_fall = 0;  /* sck falling edges seen in the current transaction */
  integer write_count = 0;

  assign w_spi_miso = r_baro_sdo_en ? r_baro_sdo : 1'bz;
  pulldown (w_spi_miso); /* same as the PULLDOWN on the FPGA pin */

  /* mosi as it was just before the current instant: what a slave with a
     real set-up time captures on a clock edge */
  wire #1 w_spi_mosi_dly = w_spi_mosi;

  initial begin
    r_baro_sdo = 1'b0;
    r_baro_sdo_en = 1'b0;
  end

  always @(negedge w_spi_cs_n) if (resetn) begin
    if (w_spi_sck !== 1'b1) begin
      $error("[ERROR]: sck is %b when cs_n falls, mode 3 needs it high", w_spi_sck);
      error_counter = error_counter + 1;
    end
    baro_bits = 0;
    baro_fall = 0;
    r_baro_sdo_en = 1'b0;
  end

  always @(negedge w_spi_sck) if (resetn && !w_spi_cs_n) begin
    baro_fall = baro_fall + 1;
    /* bit n starts at falling edge n+1: the read data goes out from bit 8 */
    if (r_baro_rw && baro_bits >= 8 && baro_fall == baro_bits + 1) begin
      r_baro_sdo = baro_reg(r_baro_addr + (baro_bits - 8)/8) >> (7 - (baro_bits % 8));
      r_baro_sdo_en = 1'b1;
    end
  end

  always @(posedge w_spi_sck) if (resetn && !w_spi_cs_n) begin
    r_mosi_at_edge = w_spi_mosi_dly;
    if (baro_fall != baro_bits + 1) begin
      $error("[ERROR]: sck rising edge %0d without its falling edge first", baro_bits);
      error_counter = error_counter + 1;
    end
    if (baro_bits == 0) r_baro_rw = r_mosi_at_edge;
    else if (baro_bits < 8) r_baro_addr = {r_baro_addr[5:0], r_mosi_at_edge};
    else r_baro_wdata = {r_baro_wdata[6:0], r_mosi_at_edge};
    baro_bits = baro_bits + 1;
    #1;
    if (w_spi_mosi !== r_mosi_at_edge) begin
      $error("[ERROR]: mosi changed on the sck rising edge of bit %0d", baro_bits - 1);
      error_counter = error_counter + 1;
    end
  end

  always @(posedge w_spi_cs_n) if (resetn) begin
    r_baro_sdo_en = 1'b0;
    if (w_spi_sck !== 1'b1) begin
      $error("[ERROR]: sck is %b when cs_n rises, mode 3 stops it high", w_spi_sck);
      error_counter = error_counter + 1;
    end
    if (r_baro_rw && r_baro_addr == lp_addr_who_am_i && baro_bits == 16) begin
      id_reads_seen = id_reads_seen + 1;
      if (id_fails_left > 0) id_fails_left = id_fails_left - 1;
    end
    else if (r_baro_rw && r_baro_addr == lp_addr_status && baro_bits == 56) begin
      if (burst_new_data(burst_count)) new_data_count = new_data_count + 1;
      burst_count = burst_count + 1;
    end
    else if (!r_baro_rw && baro_bits == 16) begin
      if (write_count >= 3 || {1'b0, r_baro_addr, r_baro_wdata} !== lp_exp_writes[47 - 16*write_count -: 16]) begin
        $error("[ERROR]: write %0d mismatch, got %h", write_count, {1'b0, r_baro_addr, r_baro_wdata});
        error_counter = error_counter + 1;
      end
      write_count = write_count + 1;
    end
    else begin
      $error("[ERROR]: unexpected transaction - rw %b addr %h, %0d bits", r_baro_rw, r_baro_addr, baro_bits);
      error_counter = error_counter + 1;
    end
  end

  /**** Second DUT with no barometer on the bus (miso stuck high): must read
        WHO_AM_I p_id_max_attempts times, then flag the error and go quiet ****/
  wire w_absent_cs_n;
  wire w_absent_id_ok;
  wire w_absent_id_error;

  baro_lps22hb #(
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
    .os24_pressure(),
    .os16_temperature(),
    .or_valid(),
    .or_id_ok(w_absent_id_ok),
    .or_id_error(w_absent_id_error),
    .or_overrun(),
    .o4_debug_state()
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

  baro_lps22hb #(
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
    .os24_pressure(),
    .os16_temperature(),
    .or_valid(),
    .or_id_ok(),
    .or_id_error(),
    .or_overrun(w_fast_overrun),
    .o4_debug_state()
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

  /**** Self-checks: each or_valid carries the data of the last burst read,
        which must have been one with P_DA = 1 ****/
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

      if (!burst_new_data(burst_count - 1)) begin
        $error("[ERROR]: sample %0d from burst %0d, which had no new data (P_DA = 0)", sample_count, burst_count - 1);
        error_counter = error_counter + 1;
      end
      else if (w_pressure !== burst_pressure(burst_count - 1) || w_temperature !== burst_temperature(burst_count - 1)) begin
        $error("[ERROR]: sample %0d mismatch - pressure %0d temperature %0d, expected %0d / %0d", sample_count,
               w_pressure, w_temperature, burst_pressure(burst_count - 1), burst_temperature(burst_count - 1));
        error_counter = error_counter + 1;
      end
      else $display("[OK]: sample %0d (burst %0d) - pressure %0d, temperature %0d", sample_count, burst_count - 1,
                    w_pressure, w_temperature);
    end
  end

  /**** Test flow ****/
  initial begin

    $dumpfile ("baro_lps22hb_tb.vcd");
    $dumpvars();

    $display("[INFO] >> Setting initial conditions.");

    reset_task();

    $display("[INFO] >> Test init");

    fork
      wait (burst_count >= 6 && w_absent_id_error);
      #(40000*`clkcycle);
    join_any
    #(500*`clkcycle); /* long enough to catch any transaction after the driver gave up */

    if (sample_count !== new_data_count || sample_count < 3) begin
      $error("[ERROR]: %0d sample(s) out for %0d burst reads with new data (%0d bursts)", sample_count, new_data_count, burst_count);
      error_counter = error_counter + 1;
    end
    else $display("[OK]: %0d burst reads, %0d with new data, %0d samples out", burst_count, new_data_count, sample_count);

    if (write_count !== 3) begin
      $error("[ERROR]: expected 3 register writes (reset + 2 config), saw %0d", write_count);
      error_counter = error_counter + 1;
    end

    if (id_reads_seen !== 3) begin
      $error("[ERROR]: expected 3 WHO_AM_I reads (2 wrong answers + 1 right), saw %0d", id_reads_seen);
      error_counter = error_counter + 1;
    end
    else $display("[OK]: driver retried WHO_AM_I until the barometer answered");

    /* 1 reset write + 10 WHO_AM_I reads */
    if (!w_absent_id_error || w_absent_id_ok || absent_txn_count !== 11) begin
      $error("[ERROR]: absent barometer - id_error %b id_ok %b after %0d transactions, expected error after 11",
             w_absent_id_error, w_absent_id_ok, absent_txn_count);
      error_counter = error_counter + 1;
    end
    else $display("[OK]: absent barometer flagged after 10 WHO_AM_I reads, bus quiet afterwards");

    if (max_txn_end >= lp_baro_slot) begin
      $error("[ERROR]: a transaction ended %0d cycles after its tick, the slot is %0d", max_txn_end, lp_baro_slot);
      error_counter = error_counter + 1;
    end
    else $display("[OK]: %0d transactions, each started on a tick; the longest ended %0d cycles after it (slot %0d)",
                  txn_start_count, max_txn_end, lp_baro_slot);

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
