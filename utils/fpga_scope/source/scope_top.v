module scope_top # (
  parameter p_num_channels        = 8,       /* 1-8 active channel lanes */

  /* width in bits (1-8) of each channel; lanes >= p_num_channels are simply
     unused, whatever they're set to. Kept as 8 separate parameters (instead
     of one packed bus) so instantiating a project is plain "p_ch2_width(4)"
     with no manual bit-packing to get wrong */
  parameter p_ch0_width = 8,
  parameter p_ch1_width = 8,
  parameter p_ch2_width = 8,
  parameter p_ch3_width = 8,
  parameter p_ch4_width = 8,
  parameter p_ch5_width = 8,
  parameter p_ch6_width = 8,
  parameter p_ch7_width = 8,

  parameter p_buffer_depth_log2   = 10,      /* ring buffer = 2^p_buffer_depth_log2 samples, see docs/protocol.md for the LEN-field size cap */
  parameter p_uart_preescaler     = 8,       /* baudrate divider, see modules/uart/uart.md */
  parameter [31:0] p_clk_freq_hz  = 32'd100_000_000 /* reported via CMD_GET_INFO for the GUI's time axis */
)(
  input clk,
  input rst, /* synchronous reset */

  /* one full byte per channel so instantiation is a straight wire-up, even
     for 1-bit channels (tie off the unused upper bits at the call site) */
  input [7:0] i_ch0,
  input [7:0] i_ch1,
  input [7:0] i_ch2,
  input [7:0] i_ch3,
  input [7:0] i_ch4,
  input [7:0] i_ch5,
  input [7:0] i_ch6,
  input [7:0] i_ch7,

  input i_uart_rx,
  output o_uart_tx
);

`include "scope_defs.vh"

/* ------------------------------------------------------------------ */
/* Elaboration-time helpers: total sample width and per-channel offset */
/* within it, from the 8 individual p_chN_width parameters              */
/* ------------------------------------------------------------------ */

function integer f_ch_width;
  input integer idx;
  begin
    case (idx)
      0: f_ch_width = p_ch0_width;
      1: f_ch_width = p_ch1_width;
      2: f_ch_width = p_ch2_width;
      3: f_ch_width = p_ch3_width;
      4: f_ch_width = p_ch4_width;
      5: f_ch_width = p_ch5_width;
      6: f_ch_width = p_ch6_width;
      7: f_ch_width = p_ch7_width;
      default: f_ch_width = 0;
    endcase
  end
endfunction

function integer f_frame_width;
  input integer num_ch;
  integer i;
  begin
    f_frame_width = 0;
    for (i = 0; i < 8; i = i + 1)
      if (i < num_ch) f_frame_width = f_frame_width + f_ch_width(i);
  end
endfunction

function integer f_channel_offset;
  input integer idx;
  input integer num_ch;
  integer i;
  begin
    f_channel_offset = 0;
    for (i = 0; i < idx; i = i + 1)
      if (i < num_ch) f_channel_offset = f_channel_offset + f_ch_width(i);
  end
endfunction

localparam lp_frame_width = f_frame_width(p_num_channels);
localparam lp_frame_bytes = (lp_frame_width + 7) / 8;
localparam lp_addr_width  = p_buffer_depth_log2;

wire [7:0] w_ch [0:7];
assign w_ch[0] = i_ch0;
assign w_ch[1] = i_ch1;
assign w_ch[2] = i_ch2;
assign w_ch[3] = i_ch3;
assign w_ch[4] = i_ch4;
assign w_ch[5] = i_ch5;
assign w_ch[6] = i_ch6;
assign w_ch[7] = i_ch7;

/* scope_trigger wants a fixed 8-bit lane per channel so any bit can be a
   trigger source regardless of that channel's configured width */
wire [63:0] w_signals64 = {i_ch7, i_ch6, i_ch5, i_ch4, i_ch3, i_ch2, i_ch1, i_ch0};

/* the buffer only ever stores the configured width of each channel, packed
   with no gaps, channel 0 at the LSB end (see docs/protocol.md) */
wire [lp_frame_width-1:0] w_sample_data;
wire [63:0] w_channel_widths_bytes; /* one byte per channel for CMD_GET_INFO, 0 = unused */

genvar gi;
generate
  for (gi = 0; gi < 8; gi = gi + 1) begin : gen_pack
    if (gi < p_num_channels) begin : gen_active
      localparam lp_w   = f_ch_width(gi);
      localparam lp_off = f_channel_offset(gi, p_num_channels);

      assign w_sample_data[lp_off +: lp_w]     = w_ch[gi][lp_w-1:0];
      assign w_channel_widths_bytes[gi*8 +: 8] = lp_w[7:0];
    end
    else begin : gen_inactive
      assign w_channel_widths_bytes[gi*8 +: 8] = 8'd0;
    end
  end
endgenerate

/* ------------------------------------------------------------------ */
/* MODE_SCOPE: trigger + ring buffer                                    */
/* ------------------------------------------------------------------ */

wire [1:0] w_ctrl_state;
wire [15:0] w_ctrl_fill_count, w_ctrl_dump_count;
wire [lp_addr_width-1:0] w_ctrl_dump_start_addr;
wire w_ctrl_cmd_arm, w_ctrl_cmd_abort;
wire [63:0] w_trig_channel_cfg;
wire w_trig_combine_mode;
wire [15:0] w_pre_trigger_count, w_post_trigger_count, w_decimation;
wire w_ctrl_wr_en;
wire [lp_addr_width-1:0] w_ctrl_wr_addr;
wire [lp_frame_width-1:0] w_ctrl_wr_data;
wire w_trigger_pulse;
wire w_buf_rd_en;
wire [lp_addr_width-1:0] w_buf_rd_addr;
wire [lp_frame_width-1:0] w_buf_rd_data;

scope_trigger # (
  .p_num_channels(p_num_channels)
) u_trigger (
  .clk(clk),
  .rst(rst),
  .i_signals(w_signals64),
  .i_channel_cfg(w_trig_channel_cfg),
  .i_combine_mode(w_trig_combine_mode),
  .o_trigger(w_trigger_pulse)
);

scope_ctrl # (
  .p_addr_width(lp_addr_width),
  .p_frame_width(lp_frame_width)
) u_ctrl (
  .clk(clk),
  .rst(rst),
  .i_cmd_arm(w_ctrl_cmd_arm),
  .i_cmd_abort(w_ctrl_cmd_abort),
  .i_pre_trigger_count(w_pre_trigger_count),
  .i_post_trigger_count(w_post_trigger_count),
  .i_decimation(w_decimation),
  .i_trigger(w_trigger_pulse),
  .i_sample_data(w_sample_data),
  .o_wr_addr(w_ctrl_wr_addr),
  .o_wr_en(w_ctrl_wr_en),
  .o_wr_data(w_ctrl_wr_data),
  .o_state(w_ctrl_state),
  .o_fill_count(w_ctrl_fill_count),
  .o_dump_count(w_ctrl_dump_count),
  .o_dump_start_addr(w_ctrl_dump_start_addr)
);

scope_capture_buffer # (
  .p_addr_width(lp_addr_width),
  .p_frame_width(lp_frame_width)
) u_buffer (
  .clk(clk),
  .i_wr_en(w_ctrl_wr_en),
  .i_wr_addr(w_ctrl_wr_addr),
  .i_wr_data(w_ctrl_wr_data),
  .i_rd_en(w_buf_rd_en),
  .i_rd_addr(w_buf_rd_addr),
  .or_rd_data(w_buf_rd_data)
);

/* ------------------------------------------------------------------ */
/* MODE_STREAM: continuous live sampling                                */
/* ------------------------------------------------------------------ */

wire w_stream_cmd_start, w_stream_cmd_abort;
wire [31:0] w_stream_sample_count;
wire w_stream_running;
wire [15:0] w_stream_remaining_count;
wire w_stream_tx_ready;
wire w_stream_sample_valid;
wire [lp_frame_width-1:0] w_stream_sample_data;

scope_streamer # (
  .p_frame_width(lp_frame_width)
) u_streamer (
  .clk(clk),
  .rst(rst),
  .i_cmd_start(w_stream_cmd_start),
  .i_cmd_abort(w_stream_cmd_abort),
  .i_sample_count_in(w_stream_sample_count),
  .i_decimation(w_decimation),
  .i_tx_ready(w_stream_tx_ready),
  .i_sample_data(w_sample_data),
  .o_running(w_stream_running),
  .o_sample_valid(w_stream_sample_valid),
  .o_sample_data(w_stream_sample_data),
  .o_remaining_count(w_stream_remaining_count)
);

/* ------------------------------------------------------------------ */
/* Command / UART interface, always present                            */
/* ------------------------------------------------------------------ */

scope_cmd_if # (
  .p_uart_preescaler(p_uart_preescaler),
  .p_num_channels(p_num_channels),
  .p_addr_width(lp_addr_width),
  .p_buffer_depth_log2(p_buffer_depth_log2),
  .p_frame_bytes(lp_frame_bytes),
  .p_frame_width(lp_frame_width),
  .p_clk_freq_hz(p_clk_freq_hz)
) u_cmd_if (
  .clk(clk),
  .rst(rst),

  .i_uart_rx(i_uart_rx),
  .o_uart_tx(o_uart_tx),

  .i_channel_widths_bytes(w_channel_widths_bytes),

  .o_ctrl_cmd_arm(w_ctrl_cmd_arm),
  .o_ctrl_cmd_abort(w_ctrl_cmd_abort),
  .o_trig_channel_cfg(w_trig_channel_cfg),
  .o_trig_combine_mode(w_trig_combine_mode),
  .o_pre_trigger_count(w_pre_trigger_count),
  .o_post_trigger_count(w_post_trigger_count),
  .o_decimation(w_decimation),
  .i_ctrl_state(w_ctrl_state),
  .i_ctrl_fill_count(w_ctrl_fill_count),
  .i_ctrl_dump_count(w_ctrl_dump_count),
  .i_ctrl_dump_start_addr(w_ctrl_dump_start_addr),

  .o_buf_rd_en(w_buf_rd_en),
  .o_buf_rd_addr(w_buf_rd_addr),
  .i_buf_rd_data(w_buf_rd_data),

  .o_stream_cmd_start(w_stream_cmd_start),
  .o_stream_cmd_abort(w_stream_cmd_abort),
  .o_stream_sample_count(w_stream_sample_count),
  .i_stream_running(w_stream_running),
  .i_stream_remaining_count(w_stream_remaining_count),
  .o_stream_tx_ready(w_stream_tx_ready),
  .i_stream_sample_valid(w_stream_sample_valid),
  .i_stream_sample_data(w_stream_sample_data),

  .o_active_mode()
);

endmodule
