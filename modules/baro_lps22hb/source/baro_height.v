/* Height above a reference point from the barometer's pressure.

   - Linear approximation of the barometric formula around the reference:
     h = (p0 - p) * dh/dp, with the slope dh/dp = R*T/(g*p0) taken at the
     reference pressure and 15 degC: 8.32 m/hPa at 1013.25 hPa, 8.77 at
     961 hPa. A fixed slope would read 5 % short at a 450 m site, so every
     zero recomputes it as p_height_per_lsb_q16 * p_default_reference / p0
     (one ~36-clock division per zero). What is left: the slope still grows
     above the reference (~1.2 % per 100 m: a 100 m climb reads ~0.5 m
     short) and with temperature (~0.35 % per degC from 15 degC).
   - Until the first i_zero the reference is p_default_reference, standard
     sea-level pressure: the output is then a rough altitude, only to look
     at (the linear slope and the weather put it metres to tens of metres
     off; ~435 m where the real one is ~445 m).
   - An i_zero pulse takes a new reference, the mean of the next
     2^p_avg_log2 samples, and its slope; the height keeps coming against
     the old reference until the new one is in. Nothing zeroes on its own: who decides when the
     drone is on the ground (a button now, a flight FSM later) sends i_zero.
   - Height comes out in 2 cm steps, 16 bits signed, saturated to
     +/-655.34 m: enough for the altitude of most take-off sites before the
     first zero, and 2 cm is below the sensor noise (~7 cm rms measured). */
module baro_height # (
  parameter p_avg_log2 = 4, /* reference = mean of 2^p_avg_log2 samples */
  parameter signed [23:0] p_default_reference = 24'sd4150272, /* reference until the first i_zero: 1013.25 hPa */
  parameter [15:0] p_height_per_lsb_q16 = 16'd6659 /* slope at p_default_reference: height per pressure LSB, in 2 cm steps, 16 fraction bits: 0.1016 (0.2032 cm) */
)(
  input clk,
  input rst,

  input signed [23:0] is24_pressure, /* 4096 LSB/hPa, from baro_lps22hb */
  input i_valid, /* one-clock pulse: new is24_pressure */
  input i_zero, /* one-clock pulse: take a new reference from the next samples */

  output reg signed [15:0] os16_height_2cm, /* height above the reference, 1 LSB = 2 cm */
  output reg or_valid, /* one-clock pulse: new os16_height_2cm, two clocks after i_valid */
  output reg or_zeroed /* the reference is a zero taken with i_zero (low: sea-level default, or a new zero being averaged) */
);

localparam lp_avg_samples = 1 << p_avg_log2;

/* Reference: the default, then the average of the samples after i_zero */
reg r_averaging;
reg [p_avg_log2:0] r_avg_count;
reg signed [24+p_avg_log2-1:0] rs_sum;
reg signed [23:0] rs24_reference;

/* Slope for a new reference: r16_slope = lp_slope_numerator / p0, a
   restoring division, one quotient bit per clock (the slope is inversely
   proportional to the reference pressure). The new reference and its slope
   are put in use together when it ends */
localparam [63:0] lp_slope_numerator = {48'd0, p_height_per_lsb_q16} * {40'd0, p_default_reference};
localparam lp_div_bits = 36; /* the numerator fits in 36 bits (~2.8e10) */

reg [15:0] r16_slope; /* slope in use, as p_height_per_lsb_q16 */
reg signed [23:0] rs24_new_reference;
reg r_dividing;
reg [5:0] r6_div_bit;
reg [24:0] r25_div_rem;
reg [lp_div_bits-1:0] r_div_quotient;
wire [24:0] w25_div_shifted = {r25_div_rem[23:0], lp_slope_numerator[r6_div_bit]};
wire w_div_fits = (w25_div_shifted >= {1'b0, rs24_new_reference});

/* Height pipeline: difference, then scale and saturate */
reg signed [24:0] rs25_diff;
reg r_diff_valid;
wire signed [41:0] ws42_scaled = rs25_diff * $signed({1'b0, r16_slope});
wire signed [25:0] ws26_height = ws42_scaled >>> 16;

always @(posedge clk) begin
  if (rst) begin
    r_averaging <= 1'b0;
    r_avg_count <= 0;
    rs_sum <= 0;
    rs24_reference <= p_default_reference;
    r16_slope <= p_height_per_lsb_q16;
    rs24_new_reference <= p_default_reference;
    r_dividing <= 1'b0;
    r6_div_bit <= 6'd0;
    r25_div_rem <= 25'd0;
    r_div_quotient <= {lp_div_bits{1'b0}};
    or_zeroed <= 1'b0;
    rs25_diff <= 25'sd0;
    r_diff_valid <= 1'b0;
    os16_height_2cm <= 16'sd0;
    or_valid <= 1'b0;
  end
  else begin
    r_diff_valid <= 1'b0;
    or_valid <= 1'b0;

    if (i_zero) begin
      or_zeroed <= 1'b0;
      r_dividing <= 1'b0;
      r_averaging <= 1'b1;
      r_avg_count <= 0;
      rs_sum <= 0;
    end
    else if (i_valid) begin
      if (r_averaging) begin
        if (r_avg_count == lp_avg_samples-1) begin
          rs24_new_reference <= (rs_sum + is24_pressure) >>> p_avg_log2;
          r_averaging <= 1'b0;
          r_dividing <= 1'b1;
          r6_div_bit <= lp_div_bits-1;
          r25_div_rem <= 25'd0;
          r_div_quotient <= {lp_div_bits{1'b0}};
        end
        else begin
          rs_sum <= rs_sum + is24_pressure;
          r_avg_count <= r_avg_count + 1'b1;
        end
      end
      /* every sample gives a height, against the reference in use */
      rs25_diff <= rs24_reference - is24_pressure; /* pressure drops as height grows */
      r_diff_valid <= 1'b1;
    end

    /* the division takes 36 clocks, much less than the time between two
       samples, and i_zero above restarts everything */
    if (r_dividing && !i_zero) begin
      r25_div_rem <= w_div_fits ? w25_div_shifted - {1'b0, rs24_new_reference} : w25_div_shifted;
      r_div_quotient[r6_div_bit] <= w_div_fits;
      if (r6_div_bit != 0) r6_div_bit <= r6_div_bit - 1'b1;
      else begin
        /* last bit: the quotient needs w_div_fits too */
        r_dividing <= 1'b0;
        rs24_reference <= rs24_new_reference;
        if (r_div_quotient[lp_div_bits-1:16] != 0) r16_slope <= 16'hFFFF; /* p0 nonsense (< ~100 hPa) */
        else r16_slope <= {r_div_quotient[15:1], w_div_fits};
        or_zeroed <= 1'b1;
      end
    end

    if (r_diff_valid) begin
      if (ws26_height > 26'sd32767) os16_height_2cm <= 16'sd32767;
      else if (ws26_height < -26'sd32768) os16_height_2cm <= -16'sd32768;
      else os16_height_2cm <= ws26_height[15:0];
      or_valid <= 1'b1;
    end
  end
end

endmodule
