module baro_lps22hb # (
  parameter p_spi_prescaler = 4, /* spi_master prescaler: sck = clk/(2*(p_spi_prescaler/2+2)), 8 clocks per bit by default (3.125 MHz at 25 MHz); the chip allows up to 10 MHz */
  parameter p_reset_wait_cycles = 125000, /* wait after SWRESET (self-clearing, the datasheet gives no time): 5 ms at 25 MHz */
  parameter [7:0] p_who_am_i = 8'hB1, /* expected WHO_AM_I readback: B1h = LPS22HB (B3h would be a LPS22HH, different registers) */
  parameter p_id_retry_wait_cycles = 25000000, /* wait before reading WHO_AM_I again after a wrong readback (default: 1 s at 25MHz) */
  parameter p_id_max_attempts = 10, /* WHO_AM_I reads before giving up (1-15), 0 = keep retrying forever */
  parameter [2:0] p_odr = 3'b011, /* CTRL_REG1 ODR[2:0]: 011 = 25 Hz (001 1 Hz, 010 10 Hz, 100 50 Hz, 101 75 Hz) */
  parameter p_en_lpfp = 1'b1, /* CTRL_REG1 EN_LPFP: extra low-pass filter on pressure */
  parameter p_lpfp_cfg = 1'b0 /* CTRL_REG1 LPFP_CFG: bandwidth ODR/9 (0) or ODR/20 (1) with the filter on, ODR/2 with it off */
)(
  input clk,
  input rst,

  input i_tick, /* one-clock pulse: the driver may start its next SPI transaction; in steady state one tick = one read */

  output o_spi_cs_n,
  output o_spi_sck,
  output o_spi_mosi,
  input  i_spi_miso,

  output reg signed [23:0] os24_pressure, /* 4096 LSB/hPa */
  output reg signed [15:0] os16_temperature, /* 100 LSB/degC */
  output reg or_valid, /* one-clock pulse: new pressure+temperature sample latched (STATUS.P_DA was set) */
  output reg or_id_ok, /* sticky: WHO_AM_I readback matched p_who_am_i */
  output reg or_id_error, /* sticky: WHO_AM_I readback did not match p_who_am_i in any of the p_id_max_attempts reads */
  output reg or_overrun, /* sticky: a tick arrived while a transaction was still in progress (the schedule is too tight) */
  output [3:0] o4_debug_state /* FSM state (st_* below), for debug only */
);

/* Register map (ST LPS22HB datasheet, DocID027083 Rev 6, section 9) */
localparam lp_addr_who_am_i  = 7'h0F;
localparam lp_addr_ctrl_reg1 = 7'h10;
localparam lp_addr_ctrl_reg2 = 7'h11;
localparam lp_addr_status    = 7'h27; /* burst start: STATUS, PRESS_OUT_XL/L/H, TEMP_OUT_L/H (27h-2Ch) */

localparam lp_ctrl_reg2_reset  = 8'h14; /* IF_ADD_INC = 1 (default), SWRESET = 1 */
localparam lp_ctrl_reg2_config = 8'h18; /* IF_ADD_INC = 1, I2C_DIS = 1: while its CS is high the chip would
                                           otherwise listen to the IMU's traffic as I2C. SWRESET clears it,
                                           so it is written after the reset */

localparam lp_burst_bytes = 6; /* STATUS + 3 pressure + 2 temperature */
localparam lp_burst_bits  = 8 + 8*lp_burst_bytes; /* command byte + 6 data bytes = 56 */

/* spi_master instance, sized to carry the 56-bit burst-read transaction */
localparam lp_spi_buffer  = 56;
localparam lp_spi_index_w = 6;

reg [lp_spi_buffer-1:0] r_spi_ip_data;
reg [lp_spi_index_w-1:0] r_spi_ip_count;
reg r_spi_valid;
wire [lp_spi_buffer-1:0] w_spi_orp_data;
wire w_spi_busy;

spi_master # (
  .p_prescaler(p_spi_prescaler),
  .p_cpol(1), /* SPI mode 3: the datasheet (7.3) stops sck high while cs is high, drives on falling edges and */
  .p_cpha(1), /* captures on rising edges. Same mode as imu_lsm6dsm, which shares the bus */
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
localparam st_reset_kick    = 4'd0;
localparam st_reset_busy    = 4'd1;
localparam st_reset_delay   = 4'd2;
localparam st_id_kick       = 4'd3;
localparam st_id_busy       = 4'd4;
localparam st_id_latch      = 4'd5;
localparam st_error         = 4'd6;
localparam st_cfg1_kick     = 4'd7;  /* CTRL_REG2: I2C_DIS */
localparam st_cfg1_busy     = 4'd8;
localparam st_cfg2_kick     = 4'd9;  /* CTRL_REG1: ODR, filter, BDU */
localparam st_cfg2_busy     = 4'd10;
localparam st_sample_wait   = 4'd11;
localparam st_burst_kick    = 4'd12;
localparam st_burst_busy    = 4'd13;
localparam st_burst_latch   = 4'd14;
localparam st_id_retry_wait = 4'd15;

reg [3:0] r_state;
assign o4_debug_state = r_state;
/* wide enough for the longest of the two waits */
localparam lp_max_wait = (p_reset_wait_cycles > p_id_retry_wait_cycles) ? p_reset_wait_cycles : p_id_retry_wait_cycles;
localparam pw_wait = (lp_max_wait > 1) ? $clog2(lp_max_wait) : 1;
reg [pw_wait-1:0] r_wait_counter;
reg [3:0] r4_id_fail_count;

/* w_spi_busy reads 0 for one clock right after a kick (spi_master hasn't
   sampled i_data_valid yet): only trust it once busy has been seen high
   since the kick (same as imu_lsm6dsm). */
reg r_spi_seen_busy;
wire w_spi_done = r_spi_seen_busy && !w_spi_busy;

/* Every SPI transaction, the power-up ones included, starts on a tick. A
   tick in the middle of a transaction is lost and flags or_overrun; ticks
   during the reset and WHO_AM_I retry waits, or after the driver gave up,
   are just ignored. */
wire w_in_transaction = (r_state == st_reset_busy) || (r_state == st_id_busy) ||
                        (r_state == st_id_latch) || (r_state == st_cfg1_busy) ||
                        (r_state == st_cfg2_busy) || (r_state == st_burst_kick) ||
                        (r_state == st_burst_busy) || (r_state == st_burst_latch);

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
    os24_pressure <= 24'sd0;
    os16_temperature <= 16'sd0;
  end
  else begin
    or_valid <= 1'b0; /* single-cycle pulse, unless overridden below */
    r_spi_valid <= 1'b0; /* single-cycle kick, unless overridden below */
    if (w_spi_busy) r_spi_seen_busy <= 1'b1;
    if (i_tick && w_in_transaction) or_overrun <= 1'b1;

    case (r_state)
      /* Software reset: configuration registers back to their defaults,
         whatever a previous FPGA image left in them */
      st_reset_kick: if (i_tick) begin
        r_spi_ip_data <= {{(lp_spi_buffer-16){1'b0}}, 1'b0, lp_addr_ctrl_reg2, lp_ctrl_reg2_reset};
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

      /* Confirm the SPI link is really talking to a LPS22HB */
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
        /* sticky: stop talking to a device that never identified itself as a LPS22HB */
      end

      /* Configuration: I2C off, then ODR / filter / BDU, which starts continuous mode */
      st_cfg1_kick: if (i_tick) begin
        r_spi_ip_data <= {{(lp_spi_buffer-16){1'b0}}, 1'b0, lp_addr_ctrl_reg2, lp_ctrl_reg2_config};
        r_spi_ip_count <= 16;
        r_spi_valid <= 1'b1;
        r_spi_seen_busy <= 1'b0;
        r_state <= st_cfg1_busy;
      end
      st_cfg1_busy: if (w_spi_done) r_state <= st_cfg2_kick;

      st_cfg2_kick: if (i_tick) begin
        /* bit 7 must be 0; BDU = 1; SIM = 0 (4-wire SPI) */
        r_spi_ip_data <= {{(lp_spi_buffer-16){1'b0}}, 1'b0, lp_addr_ctrl_reg1, 1'b0, p_odr, p_en_lpfp, p_lpfp_cfg, 1'b1, 1'b0};
        r_spi_ip_count <= 16;
        r_spi_valid <= 1'b1;
        r_spi_seen_busy <= 1'b0;
        r_state <= st_cfg2_busy;
      end
      st_cfg2_busy: if (w_spi_done) r_state <= st_sample_wait;

      /* Steady state: burst-read STATUS + pressure + temperature on every
         tick. The tick runs a bit faster than the ODR, so some reads find no
         new sample (STATUS.P_DA = 0): those are dropped, or_valid stays low */
      st_sample_wait: if (i_tick) r_state <= st_burst_kick;
      st_burst_kick: begin
        r_spi_ip_data <= {1'b1, lp_addr_status, {(lp_burst_bits-8){1'b0}}};
        r_spi_ip_count <= lp_burst_bits;
        r_spi_valid <= 1'b1;
        r_spi_seen_busy <= 1'b0;
        r_state <= st_burst_busy;
      end
      st_burst_busy: if (w_spi_done) r_state <= st_burst_latch;
      st_burst_latch: begin
        /* w_spi_orp_data[47:0]: STATUS, PRESS_OUT_XL, _L, _H, TEMP_OUT_L, _H, one byte per octet, MSb first */
        if (w_spi_orp_data[40]) begin /* STATUS.P_DA */
          os24_pressure <= {w_spi_orp_data[23:16], w_spi_orp_data[31:24], w_spi_orp_data[39:32]};
          os16_temperature <= {w_spi_orp_data[7:0], w_spi_orp_data[15:8]};
          or_valid <= 1'b1;
        end
        r_state <= st_sample_wait;
      end
    endcase
  end
end

endmodule
