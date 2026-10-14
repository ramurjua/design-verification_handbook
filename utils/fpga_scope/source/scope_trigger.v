module scope_trigger # (
  parameter p_num_channels      = 8, /* number of active channel lanes, 1-8 */
  parameter p_channel_max_width = 8  /* bits per lane, 1-16 */
)(
  input clk,
  input rst, /* synchronous reset */
  input [8*p_channel_max_width-1:0] ip_signals, /* 8 lanes, channel i in bits [p_channel_max_width*i +: p_channel_max_width] */
  input [63:0] i_channel_cfg,  /* 8 bytes, one per channel, layout in scope_defs.vh */
  input i_combine_mode,        /* 0 = AND enabled channel conditions, 1 = OR them */
  output o_trigger             /* 1-cycle pulse when the trigger condition is met */
);

`include "scope_defs.vh"

wire [7:0] w8_bit_val;      /* selected trigger-source bit per channel, this cycle */
reg  [7:0] r8_bit_val_prev; /* same, previous cycle (for edge detection) */
wire [7:0] w8_enable;
wire [7:0] w8_cond;         /* per-channel trigger condition, neutral element when disabled/unused */

genvar gi;
generate
  for (gi = 0; gi < 8; gi = gi + 1) begin : gen_ch

    wire [7:0] w8_ch_cfg = i_channel_cfg[gi*8 +: 8];
    wire [3:0] w4_bitsel = w8_ch_cfg[SCOPE_TRIG_BITSEL_LSB +: 4];
    wire [1:0] w2_type   = w8_ch_cfg[SCOPE_TRIG_TYPE_LSB +: 2];

    if (gi < p_num_channels) begin : gen_active

      wire [p_channel_max_width-1:0] wp_lane = ip_signals[gi*p_channel_max_width +: p_channel_max_width];

      /* a bit_select past the lane (only a malformed SET_TRIGGER sends one)
         reads 0 rather than a bit of the next lane */
      assign w8_bit_val[gi] = (w4_bitsel < p_channel_max_width) ? wp_lane[w4_bitsel] : 1'b0;
      assign w8_enable[gi]  = w8_ch_cfg[SCOPE_TRIG_EN_BIT];

      /* disabled channels contribute the neutral element of the combine op so
         they never influence the AND/OR reduction below */
      assign w8_cond[gi] = (~w8_enable[gi])                  ? (i_combine_mode ? 1'b0 : 1'b1) :
                            (w2_type == SCOPE_TRIG_TYPE_LEVEL_LOW)  ? (~w8_bit_val[gi]) :
                            (w2_type == SCOPE_TRIG_TYPE_LEVEL_HIGH) ?   w8_bit_val[gi]  :
                            (w2_type == SCOPE_TRIG_TYPE_EDGE_RISE)  ?  (w8_bit_val[gi] & ~r8_bit_val_prev[gi]) :
                                                                        (~w8_bit_val[gi] & r8_bit_val_prev[gi]);
    end
    else begin : gen_inactive
      assign w8_bit_val[gi] = 1'b0;
      assign w8_enable[gi]  = 1'b0;
      assign w8_cond[gi]    = i_combine_mode ? 1'b0 : 1'b1;
    end

  end
endgenerate

always @(posedge clk) begin
  if (rst) r8_bit_val_prev <= 8'd0;
  else     r8_bit_val_prev <= w8_bit_val;
end

wire w_any_enabled  = |w8_enable;
wire w_cond_reduced = i_combine_mode ? (|w8_cond) : (&w8_cond);

/* no channel enabled -> never trigger, regardless of combine mode's neutral element */
assign o_trigger = w_any_enabled & w_cond_reduced;

endmodule
