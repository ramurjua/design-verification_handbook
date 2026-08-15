module modulador_2lvl (
  input clk,
  input rst, 
  input i_on, /* transistors on */
  input i_enable_sawtooth, /* if 0 carrier is triangular if 1 carrier is sawtooth */
  input [15:0] i16_period, /*  TRIANGULAR: period = fclk / (2 * fsw) - SAWTOOTH: period = fclk / fsw */
  input signed [15:0] i16_modulator_r, /* modulator signal R S[16,15] */
  input signed [15:0] i16_modulator_s, /* modulator signal S S[16,15] */
  input signed [15:0] i16_modulator_t, /* modulator signal T S[16,15] */
  output [2:0] o3_pwm /* pwm output HIGH, phase R - S - T*/
);

reg [15:0] r16_carrier_triangular; /* carrier triangular */
reg [15:0] r16_carrier_sawtooth; /* Sawtooth carrier */
wire signed [15:0] w16_carrier_signed; /* Carrier signal signed */
wire signed [15:0] w16_carrier_signed_doubled; /* Carrier signal doubled [-1, 1[ */
reg r_up; /* Counter up */

wire signed [31:0] w32_modulator_scale_r; /* multiplication */
wire signed [15:0] w16_mod_r_scaled; /* mod scaled to period */
reg r_pwm_R; /* comparator */

wire signed [31:0] w32_modulator_scale_s; /* multiplication */
wire signed [15:0] w16_mod_s_scaled; /* mod scaled to period */
reg r_pwm_S; /* comparator */

wire signed [31:0] w32_modulator_scale_t; /* multiplication */
wire signed [15:0] w16_mod_t_scaled; /* mod scaled to period */
reg r_pwm_T; /* comparator */

/* Carrier generation: Triangular */
always @(posedge clk)
if (rst) begin
  r16_carrier_triangular <= 32'd0;
  r_up <= 1'b1;
end
else begin
  if ((r16_carrier_triangular >= (i16_period-1)) && r_up)
    r_up <= 1'b0;
  else if ((r16_carrier_triangular == 1) && !r_up)
    r_up <= 1'b1;
  else
    r_up <= r_up;

  if (r_up)
    r16_carrier_triangular <= r16_carrier_triangular + 16'd1;
  else
    r16_carrier_triangular <= r16_carrier_triangular - 16'd1;
end

/* Carrier generation: Sawtooth */
always @(posedge clk)
if (rst) begin
  r16_carrier_sawtooth <= 16'd0;
end
else begin
  if ((r16_carrier_sawtooth < (i16_period-1))) r16_carrier_sawtooth <= r16_carrier_sawtooth + 1;
  else r16_carrier_sawtooth <= 16'd0;
end

/* Carrier selection and process */
assign w16_carrier_signed = i_enable_sawtooth ? $signed(r16_carrier_sawtooth-(i16_period/2)) : $signed(r16_carrier_triangular-(i16_period/2));
assign w16_carrier_signed_doubled = $signed(w16_carrier_signed * 16'sd2);

/* Scale modulators */
assign w32_modulator_scale_r = $signed({{16{i16_modulator_r[15]}}, i16_modulator_r} * {{16{i16_period[15]}}, i16_period});
assign w16_mod_r_scaled = w32_modulator_scale_r >> 15;

assign w32_modulator_scale_s = $signed({{16{i16_modulator_s[15]}}, i16_modulator_s} * {{16{i16_period[15]}}, i16_period});
assign w16_mod_s_scaled = w32_modulator_scale_s >> 15;

assign w32_modulator_scale_t = $signed({{16{i16_modulator_t[15]}}, i16_modulator_t} * {{16{i16_period[15]}}, i16_period});
assign w16_mod_t_scaled = w32_modulator_scale_t >> 15;

/* PWM generation */
  always @(posedge clk)
    if (rst) begin
      r_pwm_R <= 1'b0;
      r_pwm_S <= 1'b0;
      r_pwm_T <= 1'b0;
    end
    else begin
      if($signed(w16_mod_r_scaled > w16_carrier_signed_doubled))
        r_pwm_R <= 1'b1;
      else
        r_pwm_R <= 1'b0;

      if($signed(w16_mod_s_scaled > w16_carrier_signed_doubled))
        r_pwm_S <= 1'b1;
      else
        r_pwm_S <= 1'b0;

      if($signed(w16_mod_t_scaled > w16_carrier_signed_doubled))
        r_pwm_T <= 1'b1;
      else
        r_pwm_T <= 1'b0;
    end

assign o3_pwm = {r_pwm_T, r_pwm_S, r_pwm_R};

endmodule