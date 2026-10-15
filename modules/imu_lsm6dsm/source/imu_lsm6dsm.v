module imu_lsm6dsm # (
  parameter p_spi_prescaler = 4, /* spi_master prescaler: sck = clk/(2*(p_spi_prescaler/2+2)), 8 clocks per bit by default (3.125 MHz at 25 MHz); the chip allows up to 10 MHz */
  parameter p_reset_wait_cycles = 1000000, /* wait after SW_RESET, based on datasheet Ton = 35ms turn-on time + margin */
  parameter [7:0] p_who_am_i = 8'h6A, /* expected WHO_AM_I readback: 6Ah = LSM6DSM/LSM6DSL, 6Ch = LSM6DSO (same registers used here) */
  parameter p_id_retry_wait_cycles = 25000000, /* wait before reading WHO_AM_I again after a wrong readback (default: 1 s at 25MHz) */
  parameter p_id_max_attempts = 10, /* WHO_AM_I reads before giving up (1-15), 0 = keep retrying forever */
  parameter [3:0] p_odr_xl = 4'b0101, /* CTRL1_XL ODR_XL[3:0]: 0101 = 208 Hz high-performance */
  parameter [1:0] p_fs_xl  = 2'b11,   /* CTRL1_XL FS_XL[1:0]: 11 = +/-8g */
  parameter [3:0] p_odr_g  = 4'b0101, /* CTRL2_G ODR_G[3:0]: 0101 = 208 Hz high-performance */
  parameter [1:0] p_fs_g   = 2'b10    /* CTRL2_G FS_G[1:0]: 10 = +/-1000 dps */
)(
  input clk,
  input rst,

  input i_tick, /* one-clock pulse: the driver may start its next SPI transaction; in steady state one tick = one sample */

  output o_spi_cs_n,
  output o_spi_sck,
  output o_spi_mosi,
  input  i_spi_miso,

  output reg signed [15:0] os16_gyro_x,
  output reg signed [15:0] os16_gyro_y,
  output reg signed [15:0] os16_gyro_z,
  output reg signed [15:0] os16_accel_x,
  output reg signed [15:0] os16_accel_y,
  output reg signed [15:0] os16_accel_z,
  output reg or_valid, /* one-clock pulse: new gyro+accel sample latched */
  output reg or_id_ok, /* sticky: WHO_AM_I readback matched p_who_am_i */
  output reg or_id_error, /* sticky: WHO_AM_I readback did not match p_who_am_i in any of the p_id_max_attempts reads */
  output reg or_overrun, /* sticky: a tick arrived while a transaction was still in progress (the schedule is too tight) */
  output [4:0] o5_debug_state /* FSM state (st_* below), for debug only */
);

/* Register map (LSM6DSM datasheet, see imu_lsm6dsm.md) */
localparam lp_addr_ctrl1_xl = 7'h10;
localparam lp_addr_ctrl2_g  = 7'h11;
localparam lp_addr_ctrl3_c  = 7'h12;
localparam lp_addr_who_am_i = 7'h0F;
localparam lp_addr_outx_l_g = 7'h22; /* burst start: OUTX_L_G .. OUTZ_H_A (22h-2Dh) */

localparam lp_ctrl3_c_reset  = 8'h01; /* SW_RESET = 1 */
localparam lp_ctrl3_c_config = 8'h44; /* BDU = 1, IF_INC = 1 */

localparam lp_burst_bytes = 12; /* 6 gyro + 6 accel data bytes */
localparam lp_burst_bits  = 8 + 8*lp_burst_bytes; /* command byte + 12 data bytes = 104 */

/* spi_master instance, sized to carry the 104-bit burst-read transaction */
localparam lp_spi_buffer  = 112;
localparam lp_spi_index_w = 7;

reg [lp_spi_buffer-1:0] r_spi_ip_data;
reg [lp_spi_index_w-1:0] r_spi_ip_count;
reg r_spi_valid;
wire [lp_spi_buffer-1:0] w_spi_orp_data;
wire w_spi_busy;

spi_master # (
  .p_prescaler(p_spi_prescaler),
  .p_cpol(1), /* SPI mode 3 (sck idles high), the only mode the datasheet documents (figures 5-10) */
  .p_cpha(1), /* needed with p_cpol = 1: cpha = 0 would be mode 2, moving mosi on the rising edge the LSM6DSM samples on */
  .p_max_data_buffer(lp_spi_buffer),
  .pw_data_index(lp_spi_index_w)
) spi_master_inst (
  .clk(clk),
  .rst(rst),
  .ip_data(r_spi_ip_data),
  .ip_data_count(r_spi_ip_count),
  .i_data_valid(r_spi_valid),
  .orp_data(w_spi_orp_data),
  .o_data_ready(),
  .or_mosi(o_spi_mosi),
  .i_miso(i_spi_miso),
  .o_sck(o_spi_sck),
  .o_busy(w_spi_busy)
);

assign o_spi_cs_n = ~w_spi_busy;

/* FSM */
localparam st_reset_kick  = 5'd0;
localparam st_reset_busy  = 5'd1;
localparam st_reset_delay = 5'd2;
localparam st_id_kick     = 5'd3;
localparam st_id_busy     = 5'd4;
localparam st_id_latch    = 5'd5;
localparam st_error       = 5'd6;
localparam st_cfg1_kick   = 5'd7;  /* CTRL3_C: BDU/IF_INC */
localparam st_cfg1_busy   = 5'd8;
localparam st_cfg2_kick   = 5'd9;  /* CTRL1_XL: accel ODR/FS */
localparam st_cfg2_busy   = 5'd10;
localparam st_cfg3_kick   = 5'd11; /* CTRL2_G: gyro ODR/FS */
localparam st_cfg3_busy   = 5'd12;
localparam st_sample_wait = 5'd13;
localparam st_burst_kick  = 5'd14;
localparam st_burst_busy  = 5'd15;
localparam st_burst_latch = 5'd16;
localparam st_id_retry_wait = 5'd17;

reg [4:0] r_state;
assign o5_debug_state = r_state;
/* wide enough for the longest of the two waits */
localparam lp_max_wait = (p_reset_wait_cycles > p_id_retry_wait_cycles) ? p_reset_wait_cycles : p_id_retry_wait_cycles;
localparam pw_wait = (lp_max_wait > 1) ? $clog2(lp_max_wait) : 1;
reg [pw_wait-1:0] r_wait_counter;
reg [3:0] r4_id_fail_count;

/* w_spi_busy reads 0 for one clock right after a kick (spi_master hasn't
   sampled i_data_valid yet), so a bare "!w_spi_busy" check would treat the
   transaction as already done before it even started. Only trust it once
   busy has actually been observed high at least once since the kick. */
reg r_spi_seen_busy;
wire w_spi_done = r_spi_seen_busy && !w_spi_busy;

/* Every SPI transaction, the power-up ones included, starts on a tick: the
   *_kick states and st_sample_wait wait for one. A tick in the middle of a
   transaction is lost and flags or_overrun; ticks during the reset and
   WHO_AM_I retry waits, or after the driver gave up, are just ignored. */
wire w_in_transaction = (r_state == st_reset_busy) || (r_state == st_id_busy) ||
                        (r_state == st_id_latch) || (r_state == st_cfg1_busy) ||
                        (r_state == st_cfg2_busy) || (r_state == st_cfg3_busy) ||
                        (r_state == st_burst_kick) || (r_state == st_burst_busy) ||
                        (r_state == st_burst_latch);

always @(posedge clk) begin
  if (rst) begin
    r_state <= st_reset_kick;
    r_wait_counter <= {pw_wait{1'b0}};
    r_spi_valid <= 1'b0;
    r_spi_ip_data <= {lp_spi_buffer{1'b0}};
    r_spi_ip_count <= {lp_spi_index_w{1'b0}};
    r_spi_seen_busy <= 1'b0;
    or_valid <= 1'b0;
    or_id_ok <= 1'b0;
    or_id_error <= 1'b0;
    or_overrun <= 1'b0;
    r4_id_fail_count <= 4'd0;
    os16_gyro_x <= 16'sd0;
    os16_gyro_y <= 16'sd0;
    os16_gyro_z <= 16'sd0;
    os16_accel_x <= 16'sd0;
    os16_accel_y <= 16'sd0;
    os16_accel_z <= 16'sd0;
  end
  else begin
    or_valid <= 1'b0; /* single-cycle pulse, unless overridden below */
    r_spi_valid <= 1'b0; /* single-cycle kick, unless overridden below */
    if (w_spi_busy) r_spi_seen_busy <= 1'b1;
    if (i_tick && w_in_transaction) or_overrun <= 1'b1;

    case (r_state)
      /* Software reset */
      st_reset_kick: if (i_tick) begin
        r_spi_ip_data <= {{(lp_spi_buffer-16){1'b0}}, 1'b0, lp_addr_ctrl3_c, lp_ctrl3_c_reset};
        r_spi_ip_count <= 16;
        r_spi_valid <= 1'b1;
        r_spi_seen_busy <= 1'b0;
        r_state <= st_reset_busy;
      end
      st_reset_busy: begin
        if (w_spi_done) begin
          r_wait_counter <= {pw_wait{1'b0}};
          r_state <= st_reset_delay;
        end
      end
      st_reset_delay: begin
        if (r_wait_counter >= p_reset_wait_cycles-1) r_state <= st_id_kick;
        else r_wait_counter <= r_wait_counter + 1'b1;
      end

      /* Confirm the SPI link is really talking to a LSM6DSM */
      st_id_kick: if (i_tick) begin
        r_spi_ip_data <= {{(lp_spi_buffer-16){1'b0}}, 1'b1, lp_addr_who_am_i, 8'h00};
        r_spi_ip_count <= 16;
        r_spi_valid <= 1'b1;
        r_spi_seen_busy <= 1'b0;
        r_state <= st_id_busy;
      end
      st_id_busy: if (w_spi_done) r_state <= st_id_latch;
      st_id_latch: begin
        if (w_spi_orp_data[7:0] == p_who_am_i) begin
          or_id_ok <= 1'b1;
          r_state <= st_cfg1_kick;
        end
        else if (p_id_max_attempts != 0 && r4_id_fail_count >= p_id_max_attempts-1) begin
          or_id_error <= 1'b1;
          r_state <= st_error;
        end
        else begin
          /* the device may just not be powered/ready yet: try again later */
          r4_id_fail_count <= r4_id_fail_count + 1'b1;
          r_wait_counter <= {pw_wait{1'b0}};
          r_state <= st_id_retry_wait;
        end
      end
      st_id_retry_wait: begin
        if (r_wait_counter >= p_id_retry_wait_cycles-1) r_state <= st_id_kick;
        else r_wait_counter <= r_wait_counter + 1'b1;
      end
      st_error: begin
        /* sticky: stop talking to a device that never identified itself as a LSM6DSM */
      end

      /* Configuration: BDU, then accelerometer ODR/FS, then gyroscope ODR/FS */
      st_cfg1_kick: if (i_tick) begin
        r_spi_ip_data <= {{(lp_spi_buffer-16){1'b0}}, 1'b0, lp_addr_ctrl3_c, lp_ctrl3_c_config};
        r_spi_ip_count <= 16;
        r_spi_valid <= 1'b1;
        r_spi_seen_busy <= 1'b0;
        r_state <= st_cfg1_busy;
      end
      st_cfg1_busy: if (w_spi_done) r_state <= st_cfg2_kick;

      st_cfg2_kick: if (i_tick) begin
        r_spi_ip_data <= {{(lp_spi_buffer-16){1'b0}}, 1'b0, lp_addr_ctrl1_xl, p_odr_xl, p_fs_xl, 1'b0, 1'b0};
        r_spi_ip_count <= 16;
        r_spi_valid <= 1'b1;
        r_spi_seen_busy <= 1'b0;
        r_state <= st_cfg2_busy;
      end
      st_cfg2_busy: if (w_spi_done) r_state <= st_cfg3_kick;

      st_cfg3_kick: if (i_tick) begin
        r_spi_ip_data <= {{(lp_spi_buffer-16){1'b0}}, 1'b0, lp_addr_ctrl2_g, p_odr_g, p_fs_g, 1'b0, 1'b0};
        r_spi_ip_count <= 16;
        r_spi_valid <= 1'b1;
        r_spi_seen_busy <= 1'b0;
        r_state <= st_cfg3_busy;
      end
      st_cfg3_busy: if (w_spi_done) r_state <= st_sample_wait;

      /* Steady state: burst-read gyro+accel on every tick */
      st_sample_wait: if (i_tick) r_state <= st_burst_kick;
      st_burst_kick: begin
        r_spi_ip_data <= {{(lp_spi_buffer-lp_burst_bits){1'b0}}, 1'b1, lp_addr_outx_l_g, {(lp_burst_bits-8){1'b0}}};
        r_spi_ip_count <= lp_burst_bits;
        r_spi_valid <= 1'b1;
        r_spi_seen_busy <= 1'b0;
        r_state <= st_burst_busy;
      end
      st_burst_busy: if (w_spi_done) r_state <= st_burst_latch;
      st_burst_latch: begin
        /* w_spi_orp_data[95:0] holds OUTX_L_G..OUTZ_H_A, one byte per octet, MSb first */
        os16_gyro_x  <= {w_spi_orp_data[87:80], w_spi_orp_data[95:88]};
        os16_gyro_y  <= {w_spi_orp_data[71:64], w_spi_orp_data[79:72]};
        os16_gyro_z  <= {w_spi_orp_data[55:48], w_spi_orp_data[63:56]};
        os16_accel_x <= {w_spi_orp_data[39:32], w_spi_orp_data[47:40]};
        os16_accel_y <= {w_spi_orp_data[23:16], w_spi_orp_data[31:24]};
        os16_accel_z <= {w_spi_orp_data[7:0],   w_spi_orp_data[15:8]};
        or_valid <= 1'b1;
        r_state <= st_sample_wait;
      end
    endcase
  end
end

endmodule
