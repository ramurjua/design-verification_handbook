module scope_ctrl # (
  parameter p_addr_width  = 10, /* buffer depth = 2^p_addr_width samples, keep <= 15 */
  parameter p_frame_width = 64  /* bits per sample, = sum of configured channel widths */
)(
  input clk,
  input rst, /* synchronous reset */

  input i_cmd_arm,   /* 1-cycle pulse: idle -> armed, latches the config below */
  input i_cmd_abort, /* 1-cycle pulse: force back to idle from any state */

  /* trigger / capture configuration, only sampled at i_cmd_arm time */
  input [15:0] i_pre_trigger_count,
  input [15:0] i_post_trigger_count,
  input [15:0] i_decimation, /* sample every N sample-clock cycles, 0 and 1 both mean "every cycle" */

  input i_trigger, /* pulse from scope_trigger, valid while armed */
  input [p_frame_width-1:0] i_sample_data,

  output reg [p_addr_width-1:0] o_wr_addr,
  output reg o_wr_en,
  output reg [p_frame_width-1:0] o_wr_data,

  output reg [1:0] o_state,
  output reg [15:0] o_fill_count,
  output reg [15:0] o_dump_count,      /* valid once o_state == SCOPE_ST_DONE */
  output reg [p_addr_width-1:0] o_dump_start_addr /* valid once o_state == SCOPE_ST_DONE */
);

`include "scope_defs.vh"

localparam lp_depth = (1 << p_addr_width);

/* decimation tick: fires every i_decimation sample-clock cycles while running */
wire w_running = (o_state == SCOPE_ST_ARMED) || (o_state == SCOPE_ST_CAPTURING);
wire w_sample_en;

scope_decimator decim (
  .clk(clk),
  .rst(rst),
  .i_enable(w_running),
  .i_decimation(i_decimation),
  .o_tick(w_sample_en)
);

/* pre/post counts clamped to what physically fits in the buffer, latched at ARM time */
reg [16:0] r17_pre_clamped;
reg [16:0] r17_post_clamped;
reg [16:0] r17_post_remaining;

wire [16:0] w17_pre_raw  = ({1'b0, i_pre_trigger_count} > lp_depth[16:0]) ? lp_depth[16:0] : {1'b0, i_pre_trigger_count};
wire [16:0] w17_sum      = w17_pre_raw + {1'b0, i_post_trigger_count};
wire [16:0] w17_post_raw = (w17_sum > lp_depth[16:0]) ? (lp_depth[16:0] - w17_pre_raw) : {1'b0, i_post_trigger_count};

/* free-running write pointer: always points at the next address to write */
reg [p_addr_width-1:0] r_wr_ptr;

always @(posedge clk) begin
  if (rst) begin
    o_state           <= SCOPE_ST_IDLE;
    r_wr_ptr           <= {p_addr_width{1'b0}};
    o_wr_en            <= 1'b0;
    o_wr_addr          <= {p_addr_width{1'b0}};
    o_wr_data          <= {p_frame_width{1'b0}};
    o_fill_count       <= 16'd0;
    o_dump_count       <= 16'd0;
    o_dump_start_addr  <= {p_addr_width{1'b0}};
    r17_pre_clamped    <= 17'd0;
    r17_post_clamped   <= 17'd0;
    r17_post_remaining <= 17'd0;
  end
  else if (i_cmd_abort) begin
    o_state <= SCOPE_ST_IDLE;
    o_wr_en <= 1'b0;
  end
  else begin
    o_wr_en <= 1'b0; /* default; pulsed below only on an actual sample tick */

    case (o_state)
      SCOPE_ST_IDLE: begin
        if (i_cmd_arm) begin
          o_state          <= SCOPE_ST_ARMED;
          r_wr_ptr          <= {p_addr_width{1'b0}};
          o_fill_count      <= 16'd0;
          r17_pre_clamped   <= w17_pre_raw;
          r17_post_clamped  <= w17_post_raw;
        end
      end

      SCOPE_ST_ARMED: begin
        if (w_sample_en) begin
          o_wr_en   <= 1'b1;
          o_wr_addr <= r_wr_ptr;
          o_wr_data <= i_sample_data;
          r_wr_ptr  <= r_wr_ptr + 1'b1;

          if (o_fill_count < r17_pre_clamped[15:0]) o_fill_count <= o_fill_count + 16'd1;
        end

        /* a trigger only counts once the pre-trigger window is full: taking
           one earlier would make the dump start in samples that were never
           written during this capture */
        if (i_trigger && o_fill_count >= r17_pre_clamped[15:0]) begin
          o_state           <= SCOPE_ST_CAPTURING;
          o_dump_start_addr <= r_wr_ptr - r17_pre_clamped[p_addr_width-1:0];
          o_dump_count      <= r17_pre_clamped[15:0] + r17_post_clamped[15:0];
          r17_post_remaining <= r17_post_clamped;
        end
      end

      SCOPE_ST_CAPTURING: begin
        if (w_sample_en) begin
          o_wr_en   <= 1'b1;
          o_wr_addr <= r_wr_ptr;
          o_wr_data <= i_sample_data;
          r_wr_ptr  <= r_wr_ptr + 1'b1;

          if (o_fill_count < (r17_pre_clamped[15:0] + r17_post_clamped[15:0]))
            o_fill_count <= o_fill_count + 16'd1;

          if (r17_post_remaining <= 17'd1) o_state <= SCOPE_ST_DONE;
          else                             r17_post_remaining <= r17_post_remaining - 17'd1;
        end
      end

      SCOPE_ST_DONE: begin
        /* holds here until scope_cmd_if streams the dump and issues i_cmd_abort
           (or the host re-arms once idle again) */
      end

      default: o_state <= SCOPE_ST_IDLE;
    endcase
  end
end

endmodule
