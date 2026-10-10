module uart_rx # (
  parameter p_preescaler = 8, /* clock cycles per bit: clock frequency / baudrate */
  parameter p_data_buffer = 16 /* number of bytes to receive */
)(
  input clk,
  input rst, /* synchronous reset */
  input i_rx, /* uart reception line (asynchronous, synchronised here) */
  output reg [8*p_data_buffer-1:0] orp_data, /* data received */
  output reg or_dv /* output data valid */
);

localparam lpw_preescaler_counter = (p_preescaler > 1) ? $clog2(p_preescaler) : 1;
localparam lp_max_data_bit = (p_data_buffer*8) - 1;
localparam lp_half_bit = (p_preescaler > 1) ? (p_preescaler/2) : 1;

/* i_rx comes from outside the clock domain */
reg [1:0] r2_rx_sync;

always@(posedge clk) begin
  if(rst) r2_rx_sync <= 2'b11;
  else r2_rx_sync <= {r2_rx_sync[0], i_rx};
end

wire w_rx = r2_rx_sync[1];

localparam st_idle = 3'd0;
localparam st_start = 3'd1;
localparam st_receive = 3'd2;
localparam st_stop = 3'd3;
localparam st_next_byte = 3'd4;
localparam st_end = 3'd5;

reg [2:0] r3_state; /* FSM state */
reg [8*p_data_buffer-1:0] rp_data; /* complete data */
reg [7:0] r8_byte_rcv; /* Actual byte receiving */

reg [15:0] r16_data_index; /* byte data index */
reg [2:0] r3_nBit; /* bit counter inside a bytes */

/* Bit timer. It is restarted on the falling edge of every start bit, so
   the sampling point of each byte is set by that byte's own start bit: half
   a bit later for the start bit itself, then once per bit period, which
   lands in the middle of every data bit and of the stop bit. The sender's
   clock only has to stay within half a bit of ours over one byte. */
reg [lpw_preescaler_counter-1:0] rp_preescaler_counter;
wire w_half_tick = (rp_preescaler_counter == (lp_half_bit-1));
wire w_uart_tick = (rp_preescaler_counter == (p_preescaler-1));

always@(posedge clk) begin
  if(rst) begin
    r3_state <= st_idle;
    r3_nBit <= 3'd0;
    or_dv <= 1'b0;
  end
  else begin
    case(r3_state)
      st_idle: begin // wait for the start bit of the first byte

        if(w_rx == 1'b0) r3_state <= st_start;
        else r3_state <= st_idle;

        rp_preescaler_counter <= 0;
        r16_data_index <= lp_max_data_bit;
        r3_nBit <= 0;
        or_dv <= 1'b0;
      end
      st_start: begin // check the start bit in its middle

        if(w_half_tick) begin
          rp_preescaler_counter <= 0;

          if(w_rx == 1'b0) r3_state <= st_receive;
          else if(r16_data_index == lp_max_data_bit) r3_state <= st_idle; // just a glitch, not a start bit
          else r3_state <= st_next_byte;
        end
        else rp_preescaler_counter <= rp_preescaler_counter + 1;

      end
      st_receive: begin // sample each data bit in its middle

        if(w_uart_tick) begin
          rp_preescaler_counter <= 0;
          r8_byte_rcv[r3_nBit] <= w_rx;
          r3_nBit <= r3_nBit + 1; // Bit counter

          if(r3_nBit == 7) r3_state <= st_stop;
        end
        else rp_preescaler_counter <= rp_preescaler_counter + 1;

      end
      st_stop: begin // check the stop bit in its middle

        if(w_uart_tick) begin
          rp_preescaler_counter <= 0;

          if(w_rx == 1'b1) begin
            rp_data[r16_data_index -: 8] <= r8_byte_rcv;
            r16_data_index <= r16_data_index - 8; // Byte counter

            if(r16_data_index == 7) r3_state <= st_end;
            else r3_state <= st_next_byte;
          end
          else r3_state <= st_idle; // framing error: drop the transfer
        end
        else rp_preescaler_counter <= rp_preescaler_counter + 1;

      end
      st_next_byte: begin // wait for the start bit of the next byte

        if(w_rx == 1'b0) r3_state <= st_start;
        else r3_state <= st_next_byte;

        rp_preescaler_counter <= 0;

      end
      st_end: begin

        orp_data <= rp_data;
        or_dv <= 1'b1;

        r3_state <= st_idle;

      end
      default: r3_state <= st_idle;
    endcase
  end
end


endmodule
