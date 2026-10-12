module scope_cmd_if # (
  parameter p_uart_preescaler   = 8,
  parameter p_num_channels      = 8,
  parameter p_addr_width        = 10,
  parameter p_buffer_depth_log2 = 10,
  parameter p_frame_bytes       = 8,
  parameter p_frame_width       = 64,
  parameter [31:0] p_clk_freq_hz = 32'd100_000_000
)(
  input clk,
  input rst, /* synchronous reset */

  input i_uart_rx,
  output o_uart_tx,

  input [63:0] i_channel_widths_bytes, /* one byte per channel, value = width 1-8, 0 = unused lane */

  /* scope_ctrl */
  output reg o_ctrl_cmd_arm,
  output reg o_ctrl_cmd_abort,
  output reg [63:0] o_trig_channel_cfg,
  output reg o_trig_combine_mode,
  output reg [15:0] o_pre_trigger_count,
  output reg [15:0] o_post_trigger_count,
  output reg [15:0] o_decimation,
  input [1:0] i_ctrl_state,
  input [15:0] i_ctrl_fill_count,
  input [15:0] i_ctrl_dump_count,
  input [p_addr_width-1:0] i_ctrl_dump_start_addr,

  /* capture buffer read port */
  output reg o_buf_rd_en,
  output reg [p_addr_width-1:0] o_buf_rd_addr,
  input [p_frame_width-1:0] i_buf_rd_data,

  /* scope_streamer */
  output reg o_stream_cmd_start,
  output reg o_stream_cmd_abort,
  output reg [31:0] o_stream_sample_count,
  input i_stream_running,
  input [15:0] i_stream_remaining_count,
  output o_stream_tx_ready, /* streamer must hold i_sample_data until this is high; prevents dropped samples */
  input i_stream_sample_valid,
  input [p_frame_width-1:0] i_stream_sample_data,

  output reg o_active_mode, /* 0 = SCOPE_MODE_SCOPE, 1 = SCOPE_MODE_STREAM */

  /* controls: 8 registers of 32 bits written by the host, control 0 at the LSB end */
  output reg [255:0] o_control_values,
  output reg [7:0] o_control_update /* 1-cycle pulse on bit N whenever control N is written, also with the value it already had */
);

`include "scope_defs.vh"

/* ------------------------------------------------------------------ */
/* UART byte layer                                                     */
/* ------------------------------------------------------------------ */

wire w_rx_dv;
wire [7:0] w8_rx_byte;

uart_rx # (
  .p_preescaler(p_uart_preescaler),
  .p_data_buffer(1)
) u_uart_rx (
  .clk(clk),
  .rst(rst),
  .i_rx(i_uart_rx),
  .orp_data(w8_rx_byte),
  .or_dv(w_rx_dv)
);

reg r_tx_dv;
reg [7:0] r8_tx_byte;
wire w_tx_ready;

uart_tx # (
  .p_preescaler(p_uart_preescaler),
  .p_data_buffer(1)
) u_uart_tx (
  .clk(clk),
  .rst(rst),
  .ip_data(r8_tx_byte),
  .i_dv(r_tx_dv),
  .o_ready(w_tx_ready),
  .o_tx(o_uart_tx)
);

/* ------------------------------------------------------------------ */
/* RX frame parser: SYNC / CMD / LEN_H / LEN_L / PAYLOAD / CHK         */
/* runs independently of the command dispatcher below so a CMD_ABORT   */
/* can interrupt a long CMD_DUMP / CMD_STREAM_START transfer           */
/* ------------------------------------------------------------------ */

localparam RX_WAIT_SYNC = 3'd0, RX_CMD = 3'd1, RX_LENH = 3'd2, RX_LENL = 3'd3,
           RX_PAYLOAD   = 3'd4, RX_CHK = 3'd5;

reg [2:0] r3_rx_state;
reg [7:0] r8_rx_cmd;
reg [15:0] r16_rx_len;
reg [7:0] r8_rx_payload [0:18]; /* largest defined payload is 15 B (CMD_SET_TRIGGER) */
reg [4:0] r5_rx_idx;
reg [7:0] r8_rx_chk_acc;
reg r_rx_frame_valid; /* 1-cycle pulse once a well-formed frame has been received */

always @(posedge clk) begin
  r_rx_frame_valid <= 1'b0;

  if (rst) begin
    r3_rx_state <= RX_WAIT_SYNC;
  end
  else if (w_rx_dv) begin
    case (r3_rx_state)
      RX_WAIT_SYNC: begin
        if (w8_rx_byte == SCOPE_SYNC_HOST) begin
          r3_rx_state   <= RX_CMD;
          r8_rx_chk_acc <= 8'd0;
        end
      end
      RX_CMD: begin
        r8_rx_cmd     <= w8_rx_byte;
        r8_rx_chk_acc <= r8_rx_chk_acc ^ w8_rx_byte;
        r3_rx_state   <= RX_LENH;
      end
      RX_LENH: begin
        r16_rx_len[15:8] <= w8_rx_byte;
        r8_rx_chk_acc    <= r8_rx_chk_acc ^ w8_rx_byte;
        r3_rx_state      <= RX_LENL;
      end
      RX_LENL: begin
        r16_rx_len[7:0] <= w8_rx_byte;
        r8_rx_chk_acc   <= r8_rx_chk_acc ^ w8_rx_byte;
        r5_rx_idx       <= 5'd0;
        r3_rx_state     <= ({r16_rx_len[15:8], w8_rx_byte} == 16'd0) ? RX_CHK : RX_PAYLOAD;
      end
      RX_PAYLOAD: begin
        if (r5_rx_idx <= 5'd18) r8_rx_payload[r5_rx_idx] <= w8_rx_byte;
        r8_rx_chk_acc <= r8_rx_chk_acc ^ w8_rx_byte;
        r5_rx_idx     <= r5_rx_idx + 1'b1;
        /* a well-formed frame never claims LEN > 19; this guard just keeps a
           corrupt/hostile LEN from parsing forever instead of hitting RX_CHK */
        if ((r5_rx_idx == r16_rx_len[4:0] - 1'b1) || (r5_rx_idx == 5'd18)) r3_rx_state <= RX_CHK;
      end
      RX_CHK: begin
        if (w8_rx_byte == r8_rx_chk_acc) r_rx_frame_valid <= 1'b1;
        r3_rx_state <= RX_WAIT_SYNC;
      end
      default: r3_rx_state <= RX_WAIT_SYNC;
    endcase
  end
end

/* ------------------------------------------------------------------ */
/* Command dispatcher / response sender                                */
/* ------------------------------------------------------------------ */

localparam CST_IDLE           = 4'd0,
           CST_SEND_HDR       = 4'd1,
           CST_SEND_LOCAL     = 4'd2,
           CST_SEND_CHK       = 4'd3,
           CST_DUMP_HDR       = 4'd4,
           CST_DUMP_ADDR      = 4'd5,
           CST_DUMP_WAIT      = 4'd6,
           CST_DUMP_LATCH     = 4'd9,
           CST_DUMP_SENDBYTE  = 4'd7,
           CST_STREAM_BYTE    = 4'd8;

localparam POST_NONE = 1'd0, POST_STREAM_BURST = 1'd1;

reg [3:0] r4_state;
reg [7:0] r8_resp_cmd;
reg [15:0] r16_resp_len;
reg [7:0] r8_resp_payload [0:23]; /* GET_INFO is the largest fixed response: 17 B */
reg [4:0] r5_send_idx;
reg [1:0] r2_hdr_idx;
reg [7:0] r8_tx_chk_acc;
reg r_post_action;

/* dump streaming */
reg [p_addr_width-1:0] r_dump_addr;
reg [15:0] r16_dump_samples_left;
reg [3:0] r4_dump_byte_idx;
/* byte-padded (p_frame_bytes*8), not bit-tight (p_frame_width): sent out
   p_frame_bytes*8 -: 8 at a time below, and p_frame_width isn't generally
   a multiple of 8 (e.g. 2 channels x 1 bit = 2 bits, 1 byte) - indexing a
   [p_frame_width-1:0] reg with an 8-bit slice would read past its declared
   range and pull in X for the padding bits. The narrower i_buf_rd_data
   zero-extends into this on assignment, same as it's laid out in the
   capture buffer/GET_INFO's own byte-packed view. */
reg [(p_frame_bytes*8)-1:0] r_dump_sample_reg;

/* stream burst */
reg [(p_frame_bytes*8)-1:0] r_stream_sample_reg; /* byte-padded, see r_dump_sample_reg above */
reg [3:0] r4_stream_byte_idx;
reg r_stream_have_sample;

/* streamer must hold its sample steady until we've latched it into
   r_stream_sample_reg; only then are we ready for the next one */
assign o_stream_tx_ready = (r4_state == CST_STREAM_BYTE) && !r_stream_have_sample;

wire w_sys_idle = (o_active_mode == SCOPE_MODE_SCOPE) ? (i_ctrl_state == SCOPE_ST_IDLE) : (!i_stream_running);

/* the control a CMD_CONTROL_WRITE / CMD_CONTROL_READ frame names in its first payload byte */
wire [7:0] w8_control_idx = r8_rx_payload[0];
wire w_control_idx_ok = (w8_control_idx < SCOPE_NUM_CONTROLS);
wire [31:0] w32_control_value = o_control_values[{w8_control_idx[2:0], 5'd0} +: 32];

/* w_tx_ready only drops the cycle *after* r_tx_dv is asserted (u_uart_tx's
   own idle->st_start transition takes a cycle to land), so every send state
   below re-checks "&& !r_tx_dv" too - otherwise the still-stale w_tx_ready
   lets the very next cycle fire a second, premature byte before uart_tx has
   reacted to the first one, shifting every following byte by one position. */

always @(posedge clk) begin
  o_ctrl_cmd_arm      <= 1'b0;
  o_ctrl_cmd_abort    <= 1'b0;
  o_stream_cmd_start  <= 1'b0;
  o_stream_cmd_abort  <= 1'b0;
  o_control_update    <= 8'd0;
  r_tx_dv <= 1'b0; /* re-driven below where needed */

  if (rst) begin
    r4_state    <= CST_IDLE;
    o_active_mode <= SCOPE_MODE_SCOPE;
    o_pre_trigger_count  <= 16'd0;
    o_post_trigger_count <= 16'd0;
    o_decimation          <= 16'd1;
    o_trig_channel_cfg    <= 64'd0;
    o_trig_combine_mode   <= 1'b0;
    o_buf_rd_en <= 1'b0;
    o_control_values <= 256'd0;
  end
  else if (r_rx_frame_valid && r8_rx_cmd == SCOPE_CMD_ABORT) begin
    /* highest priority: interrupt whatever is in flight, from any state */
    o_ctrl_cmd_abort   <= 1'b1;
    o_stream_cmd_abort <= 1'b1;
    r8_resp_cmd    <= SCOPE_CMD_ABORT;
    r8_resp_payload[0] <= SCOPE_STATUS_OK;
    r16_resp_len   <= 16'd1;
    r_post_action  <= POST_NONE;
    r2_hdr_idx     <= 2'd0;
    r4_state       <= CST_SEND_HDR;
  end
  else begin
    case (r4_state)

      CST_IDLE: begin
        o_buf_rd_en <= 1'b0;

        if (r_rx_frame_valid) begin
          case (r8_rx_cmd)

            SCOPE_CMD_GET_INFO: begin
              r8_resp_payload[0]  <= SCOPE_PROTOCOL_VERSION;
              r8_resp_payload[1]  <= (SCOPE_MODES_MASK_SCOPE | SCOPE_MODES_MASK_STREAM);
              r8_resp_payload[2]  <= p_num_channels[7:0];
              r8_resp_payload[3]  <= i_channel_widths_bytes[7:0];
              r8_resp_payload[4]  <= i_channel_widths_bytes[15:8];
              r8_resp_payload[5]  <= i_channel_widths_bytes[23:16];
              r8_resp_payload[6]  <= i_channel_widths_bytes[31:24];
              r8_resp_payload[7]  <= i_channel_widths_bytes[39:32];
              r8_resp_payload[8]  <= i_channel_widths_bytes[47:40];
              r8_resp_payload[9]  <= i_channel_widths_bytes[55:48];
              r8_resp_payload[10] <= i_channel_widths_bytes[63:56];
              r8_resp_payload[11] <= p_buffer_depth_log2[7:0];
              r8_resp_payload[12] <= p_frame_bytes[7:0];
              r8_resp_payload[13] <= p_clk_freq_hz[31:24];
              r8_resp_payload[14] <= p_clk_freq_hz[23:16];
              r8_resp_payload[15] <= p_clk_freq_hz[15:8];
              r8_resp_payload[16] <= p_clk_freq_hz[7:0];
              r16_resp_len <= 16'd17;
              r8_resp_cmd  <= SCOPE_CMD_GET_INFO;
              r_post_action <= POST_NONE;
              r2_hdr_idx <= 2'd0;
              r4_state <= CST_SEND_HDR;
            end

            SCOPE_CMD_SET_TRIGGER: begin
              if (w_sys_idle) begin
                o_trig_channel_cfg[7:0]    <= r8_rx_payload[0];
                o_trig_channel_cfg[15:8]   <= r8_rx_payload[1];
                o_trig_channel_cfg[23:16]  <= r8_rx_payload[2];
                o_trig_channel_cfg[31:24]  <= r8_rx_payload[3];
                o_trig_channel_cfg[39:32]  <= r8_rx_payload[4];
                o_trig_channel_cfg[47:40]  <= r8_rx_payload[5];
                o_trig_channel_cfg[55:48]  <= r8_rx_payload[6];
                o_trig_channel_cfg[63:56]  <= r8_rx_payload[7];
                o_trig_combine_mode        <= r8_rx_payload[8][0];
                o_pre_trigger_count        <= {r8_rx_payload[9],  r8_rx_payload[10]};
                o_post_trigger_count       <= {r8_rx_payload[11], r8_rx_payload[12]};
                o_decimation               <= {r8_rx_payload[13], r8_rx_payload[14]};
                r8_resp_payload[0] <= SCOPE_STATUS_OK;
              end
              else r8_resp_payload[0] <= SCOPE_STATUS_ERROR;

              r16_resp_len <= 16'd1;
              r8_resp_cmd  <= SCOPE_CMD_SET_TRIGGER;
              r_post_action <= POST_NONE;
              r2_hdr_idx <= 2'd0;
              r4_state <= CST_SEND_HDR;
            end

            SCOPE_CMD_ARM: begin
              if (o_active_mode == SCOPE_MODE_SCOPE && i_ctrl_state == SCOPE_ST_IDLE) begin
                o_ctrl_cmd_arm <= 1'b1;
                r8_resp_payload[0] <= SCOPE_STATUS_OK;
              end
              else r8_resp_payload[0] <= SCOPE_STATUS_ERROR;

              r16_resp_len <= 16'd1;
              r8_resp_cmd  <= SCOPE_CMD_ARM;
              r_post_action <= POST_NONE;
              r2_hdr_idx <= 2'd0;
              r4_state <= CST_SEND_HDR;
            end

            SCOPE_CMD_GET_STATUS: begin
              if (o_active_mode == SCOPE_MODE_SCOPE) begin
                r8_resp_payload[0] <= {6'd0, i_ctrl_state};
                r8_resp_payload[1] <= i_ctrl_fill_count[15:8];
                r8_resp_payload[2] <= i_ctrl_fill_count[7:0];
              end
              else begin
                r8_resp_payload[0] <= {7'd0, i_stream_running};
                r8_resp_payload[1] <= i_stream_remaining_count[15:8];
                r8_resp_payload[2] <= i_stream_remaining_count[7:0];
              end
              r16_resp_len <= 16'd3;
              r8_resp_cmd  <= SCOPE_CMD_GET_STATUS;
              r_post_action <= POST_NONE;
              r2_hdr_idx <= 2'd0;
              r4_state <= CST_SEND_HDR;
            end

            SCOPE_CMD_SET_MODE: begin
              if (w_sys_idle) begin
                o_active_mode <= r8_rx_payload[0][0];
                r8_resp_payload[0] <= SCOPE_STATUS_OK;
              end
              else r8_resp_payload[0] <= SCOPE_STATUS_ERROR;

              r16_resp_len <= 16'd1;
              r8_resp_cmd  <= SCOPE_CMD_SET_MODE;
              r_post_action <= POST_NONE;
              r2_hdr_idx <= 2'd0;
              r4_state <= CST_SEND_HDR;
            end

            SCOPE_CMD_STREAM_START: begin
              if (o_active_mode == SCOPE_MODE_STREAM && !i_stream_running) begin
                o_stream_sample_count <= {r8_rx_payload[0], r8_rx_payload[1], r8_rx_payload[2], r8_rx_payload[3]};
                o_stream_cmd_start    <= 1'b1;
                r8_resp_payload[0]    <= SCOPE_STATUS_OK;
                r_post_action <= POST_STREAM_BURST;
              end
              else begin
                r8_resp_payload[0] <= SCOPE_STATUS_ERROR;
                r_post_action <= POST_NONE;
              end

              r16_resp_len <= 16'd1;
              r8_resp_cmd  <= SCOPE_CMD_STREAM_START;
              r2_hdr_idx <= 2'd0;
              r4_state <= CST_SEND_HDR;
            end

            SCOPE_CMD_DUMP: begin
              if (o_active_mode == SCOPE_MODE_SCOPE && i_ctrl_state == SCOPE_ST_DONE) begin
                r_dump_addr           <= i_ctrl_dump_start_addr;
                r16_dump_samples_left <= i_ctrl_dump_count;
                r16_resp_len          <= i_ctrl_dump_count * p_frame_bytes[15:0];
                r8_resp_cmd           <= SCOPE_CMD_DUMP;
                r2_hdr_idx <= 2'd0;
                r4_state <= CST_DUMP_HDR;
              end
              /* else: invalid request, silently ignored per protocol.md */
            end

            /* accepted in any mode and capture state: nothing here touches
               the capture. All 32 bits change in this one cycle, and only
               after the frame's checksum has passed (r_rx_frame_valid). The
               length is checked too, so a short frame cannot load payload
               bytes left over from an earlier command. */
            SCOPE_CMD_CONTROL_WRITE: begin
              if (r16_rx_len == 16'd5 && w_control_idx_ok) begin
                o_control_values[{w8_control_idx[2:0], 5'd0} +: 32] <= {r8_rx_payload[1], r8_rx_payload[2], r8_rx_payload[3], r8_rx_payload[4]};
                o_control_update[w8_control_idx[2:0]] <= 1'b1;
                r8_resp_payload[0] <= SCOPE_STATUS_OK;
              end
              else r8_resp_payload[0] <= SCOPE_STATUS_ERROR;

              r16_resp_len <= 16'd1;
              r8_resp_cmd  <= SCOPE_CMD_CONTROL_WRITE;
              r_post_action <= POST_NONE;
              r2_hdr_idx <= 2'd0;
              r4_state <= CST_SEND_HDR;
            end

            SCOPE_CMD_CONTROL_READ: begin
              if (r16_rx_len == 16'd1 && w_control_idx_ok) begin
                r8_resp_payload[0] <= w8_control_idx;
                r8_resp_payload[1] <= w32_control_value[31:24];
                r8_resp_payload[2] <= w32_control_value[23:16];
                r8_resp_payload[3] <= w32_control_value[15:8];
                r8_resp_payload[4] <= w32_control_value[7:0];
                r16_resp_len <= 16'd5;
                r8_resp_cmd  <= SCOPE_CMD_CONTROL_READ;
                r_post_action <= POST_NONE;
                r2_hdr_idx <= 2'd0;
                r4_state <= CST_SEND_HDR;
              end
              /* else: no such control, silently ignored per protocol.md */
            end

            default: ; /* unknown opcode, ignored */
          endcase
        end
      end

      /* ---- generic small-response header/payload/checksum ---- */

      CST_SEND_HDR: begin
        if (w_tx_ready && !r_tx_dv) begin
          case (r2_hdr_idx)
            2'd0: begin r8_tx_byte <= SCOPE_SYNC_DEV; r_tx_dv <= 1'b1; r8_tx_chk_acc <= 8'd0; end
            2'd1: begin r8_tx_byte <= r8_resp_cmd; r_tx_dv <= 1'b1; r8_tx_chk_acc <= r8_tx_chk_acc ^ r8_resp_cmd; end
            2'd2: begin r8_tx_byte <= r16_resp_len[15:8]; r_tx_dv <= 1'b1; r8_tx_chk_acc <= r8_tx_chk_acc ^ r16_resp_len[15:8]; end
            2'd3: begin
              r8_tx_byte <= r16_resp_len[7:0];
              r_tx_dv <= 1'b1;
              r8_tx_chk_acc <= r8_tx_chk_acc ^ r16_resp_len[7:0];
            end
          endcase

          if (r2_hdr_idx == 2'd3) begin
            r5_send_idx <= 5'd0;
            r4_state    <= (r16_resp_len == 16'd0) ? CST_SEND_CHK : CST_SEND_LOCAL;
          end
          else r2_hdr_idx <= r2_hdr_idx + 1'b1;
        end
      end

      CST_SEND_LOCAL: begin
        if (w_tx_ready && !r_tx_dv) begin
          r8_tx_byte    <= r8_resp_payload[r5_send_idx];
          r_tx_dv <= 1'b1;
          r8_tx_chk_acc <= r8_tx_chk_acc ^ r8_resp_payload[r5_send_idx];

          if (r5_send_idx == r16_resp_len[4:0] - 1'b1) r4_state <= CST_SEND_CHK;
          else r5_send_idx <= r5_send_idx + 1'b1;
        end
      end

      CST_SEND_CHK: begin
        if (w_tx_ready && !r_tx_dv) begin
          r8_tx_byte <= r8_tx_chk_acc;
          r_tx_dv <= 1'b1;

          if (r_post_action == POST_STREAM_BURST && r8_resp_payload[0] == SCOPE_STATUS_OK) begin
            r4_stream_byte_idx   <= 4'd0;
            r_stream_have_sample <= 1'b0;
            r4_state <= CST_STREAM_BYTE;
          end
          else r4_state <= CST_IDLE;
        end
      end

      /* ---- CMD_DUMP: header shares the field layout above, then the ring
             buffer is read sample by sample instead of a local array ---- */

      CST_DUMP_HDR: begin
        if (w_tx_ready && !r_tx_dv) begin
          case (r2_hdr_idx)
            2'd0: begin r8_tx_byte <= SCOPE_SYNC_DEV; r_tx_dv <= 1'b1; r8_tx_chk_acc <= 8'd0; end
            2'd1: begin r8_tx_byte <= r8_resp_cmd; r_tx_dv <= 1'b1; r8_tx_chk_acc <= r8_tx_chk_acc ^ r8_resp_cmd; end
            2'd2: begin r8_tx_byte <= r16_resp_len[15:8]; r_tx_dv <= 1'b1; r8_tx_chk_acc <= r8_tx_chk_acc ^ r16_resp_len[15:8]; end
            2'd3: begin
              r8_tx_byte <= r16_resp_len[7:0];
              r_tx_dv <= 1'b1;
              r8_tx_chk_acc <= r8_tx_chk_acc ^ r16_resp_len[7:0];
            end
          endcase

          if (r2_hdr_idx == 2'd3)
            r4_state <= (r16_dump_samples_left == 16'd0) ? CST_SEND_CHK : CST_DUMP_ADDR;
          else r2_hdr_idx <= r2_hdr_idx + 1'b1;
        end
      end

      CST_DUMP_ADDR: begin
        o_buf_rd_en   <= 1'b1;
        o_buf_rd_addr <= r_dump_addr;
        r4_state      <= CST_DUMP_WAIT;
      end

      /* scope_capture_buffer's or_rd_data is a registered (BRAM-style) read
         output: i_rd_en/i_rd_addr asserted this state only become visible to
         the buffer next cycle, and its own registered read then takes one
         more cycle after that to land in or_rd_data - so the earliest cycle
         i_buf_rd_data is actually valid is 2 states after CST_DUMP_ADDR, not
         1. Capturing here (right after deasserting rd_en) would grab the
         *previous* read's stale value instead. */
      CST_DUMP_WAIT: begin
        o_buf_rd_en <= 1'b0;
        r4_state    <= CST_DUMP_LATCH;
      end

      CST_DUMP_LATCH: begin
        r_dump_sample_reg  <= i_buf_rd_data;
        r4_dump_byte_idx   <= p_frame_bytes[3:0] - 4'd1; /* MSB first */
        r4_state           <= CST_DUMP_SENDBYTE;
      end

      CST_DUMP_SENDBYTE: begin
        if (w_tx_ready && !r_tx_dv) begin
          r8_tx_byte    <= r_dump_sample_reg[8*r4_dump_byte_idx +: 8];
          r_tx_dv <= 1'b1;
          r8_tx_chk_acc <= r8_tx_chk_acc ^ r_dump_sample_reg[8*r4_dump_byte_idx +: 8];

          if (r4_dump_byte_idx == 4'd0) begin
            r_dump_addr           <= r_dump_addr + 1'b1;
            r16_dump_samples_left <= r16_dump_samples_left - 16'd1;
            r4_state <= (r16_dump_samples_left == 16'd1) ? CST_SEND_CHK : CST_DUMP_ADDR;
          end
          else r4_dump_byte_idx <= r4_dump_byte_idx - 1'b1;
        end
      end

      /* ---- CMD_STREAM_START burst: raw sample words, no envelope ---- */

      CST_STREAM_BYTE: begin
        if (!i_stream_running && !r_stream_have_sample) begin
          r4_state <= CST_IDLE; /* burst finished (or aborted) */
        end
        else if (i_stream_sample_valid && !r_stream_have_sample) begin
          r_stream_sample_reg  <= i_stream_sample_data;
          r_stream_have_sample <= 1'b1;
          r4_stream_byte_idx   <= p_frame_bytes[3:0] - 4'd1;
        end
        else if (r_stream_have_sample && w_tx_ready && !r_tx_dv) begin
          r8_tx_byte <= r_stream_sample_reg[8*r4_stream_byte_idx +: 8];
          r_tx_dv <= 1'b1;

          if (r4_stream_byte_idx == 4'd0) r_stream_have_sample <= 1'b0;
          else r4_stream_byte_idx <= r4_stream_byte_idx - 1'b1;
        end
      end

      default: r4_state <= CST_IDLE;
    endcase
  end
end

endmodule
