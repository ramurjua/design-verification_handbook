module scope_trigger # (
  parameter p_num_channels = 8 /* number of active channel lanes, 1-8 */
)(
  input clk,
  input rst, /* synchronous reset */
  input [63:0] i_signals,      /* 8 lanes x 8 bits, channel i lives in bits [8*i+7 : 8*i] */
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
    wire [2:0] w3_bitsel = w8_ch_cfg[SCOPE_TRIG_BITSEL_LSB +: 3];
    wire [1:0] w2_type   = w8_ch_cfg[SCOPE_TRIG_TYPE_LSB +: 2];

    if (gi < p_num_channels) begin : gen_active

      assign w8_bit_val[gi] = i_signals[gi*8 + w3_bitsel];
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
