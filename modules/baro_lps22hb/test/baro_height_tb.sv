/**** Global timescale ****/
`timescale 10ns/10ns
`define clkcycle 4

module baro_height_tb();

  integer error_counter = 0;

  reg clk25;
  reg resetn;

  initial begin
    clk25 = 1'b0;
    #(`clkcycle/2);
    forever
    #(`clkcycle/2) clk25 = ~clk25;
  end

  /**** DUT, default parameters: sea-level reference until i_zero, then the
        mean of the 16 samples after it; height in 2 cm steps ****/
  reg signed [23:0] r_pressure = 24'sd0;
  reg r_valid = 1'b0;
  reg r_zero = 1'b0;
  wire signed [15:0] w_height;
  wire w_valid;
  wire w_zeroed;

  baro_height dut (
    .clk(clk25),
    .rst(!resetn),
    .is24_pressure(r_pressure),
    .i_valid(r_valid),
    .i_zero(r_zero),
    .os16_height_2cm(w_height),
    .or_valid(w_valid),
    .or_zeroed(w_zeroed)
  );

  integer out_count = 0;
  always @(posedge clk25) if (resetn && w_valid) out_count = out_count + 1;

  /* one pressure sample, with gaps between samples as from the driver */
  task sample(input signed [23:0] p);
  begin
    @(posedge clk25);
    r_pressure <= p;
    r_valid <= 1'b1;
    @(posedge clk25);
    r_valid <= 1'b0;
    repeat (60) @(posedge clk25); /* more than the 36-clock slope division after a zero (40 ms on the board) */
  end
  endtask

  task zero_pulse;
  begin
    @(posedge clk25);
    r_zero <= 1'b1;
    @(posedge clk25);
    r_zero <= 1'b0;
  end
  endtask

  /* expected height in cm from the barometric formula itself,
     h = 44330.8 * (1 - (p/p0)^0.190263) m, to check the linear version */
  function real formula_cm(input real p0, input real p);
    formula_cm = 4433080.0 * (1.0 - $pow(p / p0, 0.190263));
  endfunction

  /* one sample at pressure p, its height (2 cm steps) against the formula
     with reference p0, within tol_cm */
  task check_height(input signed [23:0] p0, input signed [23:0] p, input real tol_cm, input [639:0] what);
    integer count_before;
    real expected;
    real got;
  begin
    count_before = out_count;
    sample(p);
    expected = formula_cm(p0 / 4096.0, p / 4096.0);
    got = 2.0 * $itor(w_height);
    if (out_count != count_before + 1) begin
      $error("[ERROR]: %0s - no output for the sample", what);
      error_counter = error_counter + 1;
    end
    else if (got > expected + tol_cm || got < expected - tol_cm) begin
      $error("[ERROR]: %0s - height %0.0f cm, the barometric formula gives %0.1f cm (tolerance %0.1f)", what, got, expected, tol_cm);
      error_counter = error_counter + 1;
    end
    else $display("[OK]: %0s - height %0.0f cm (formula %0.1f cm)", what, got, expected);
  end
  endtask

  localparam signed [23:0] lp_sea_level = 24'sd4150272; /* 1013.25 hPa, the DUT's default reference */
  localparam signed [23:0] lp_p0 = 24'sd3936256;        /* 961.0 hPa, the take-off site (as on the board, ~445 m) */
  integer i;

  initial begin
    $dumpfile ("baro_height_tb.vcd");
    $dumpvars();

    resetn <= 0;
    #(20*`clkcycle);
    resetn <= 1;

    /* before any i_zero: altitude against sea level, from the first sample.
       The linear slope reads ~2 % short at this height */
    check_height(lp_sea_level, lp_p0, 1200.0, "no zero yet, altitude of a 961 hPa site");
    if (w_zeroed) begin
      $error("[ERROR]: or_zeroed high without any i_zero");
      error_counter = error_counter + 1;
    end
    check_height(lp_sea_level, lp_sea_level, 0.5, "no zero yet, at sea-level pressure");
    sample(24'sd2867200); /* 700 hPa, ~3000 m: beyond +655 m */
    if (w_height !== 16'sd32767) begin
      $error("[ERROR]: 700 hPa against sea level should saturate at 32767 (655.34 m), got %0d", w_height);
      error_counter = error_counter + 1;
    end
    else $display("[OK]: no zero yet, a 3000 m site saturates at +655.34 m");

    /* i_zero at the site: the 16 samples after it still give heights
       against the old reference (no gap), then the new reference is in */
    check_height(lp_sea_level, lp_p0, 1200.0, "back at the site");
    zero_pulse();
    for (i = 0; i < 16; i = i + 1) sample(lp_p0 + ((i % 2) ? 24'sd5 : -24'sd5));
    if (!w_zeroed || out_count != 4 + 16 || w_height < 16'sd20000) begin
      $error("[ERROR]: after i_zero + 16 samples zeroed %b, %0d outputs, height %0d (expected 1, 20, still the altitude)",
             w_zeroed, out_count, w_height);
      error_counter = error_counter + 1;
    end
    else $display("[OK]: i_zero: 16 samples averaged, heights kept coming against sea level meanwhile");

    /* heights around the site: the linear approximation against the formula */
    check_height(lp_p0, lp_p0, 2.0, "zeroed, at the reference");
    check_height(lp_p0, lp_p0 - 24'sd467, 2.5, "1 m up");
    check_height(lp_p0, lp_p0 + 24'sd467, 2.5, "1 m down");
    check_height(lp_p0, lp_p0 - 24'sd4670, 3.0, "10 m up");
    check_height(lp_p0, lp_p0 - 24'sd46700, 70.0, "100 m up (linear reads ~0.5 m short)");

    /* saturation below */
    sample(lp_p0 + 24'sd1000000);
    if (w_height !== -16'sd32768) begin
      $error("[ERROR]: 2000 m down should saturate at -32768 (-655.36 m), got %0d", w_height);
      error_counter = error_counter + 1;
    end
    else $display("[OK]: saturates at -655.36 m");

    /* re-zero 10 m up, then back down */
    zero_pulse();
    for (i = 0; i < 16; i = i + 1) sample(lp_p0 - 24'sd4670);
    if (!w_zeroed) begin
      $error("[ERROR]: no new reference after i_zero + 16 samples");
      error_counter = error_counter + 1;
    end
    check_height(lp_p0 - 24'sd4670, lp_p0 - 24'sd4670, 2.0, "re-zeroed 10 m up, at the new reference");
    check_height(lp_p0 - 24'sd4670, lp_p0, 3.0, "back down 10 m from there");

    if (error_counter == 0) $display("[OK] >> All checks passed");
    else $display("[ERROR] >> %0d check(s) failed", error_counter);
    $finish();
  end

endmodule
