module uart_tx # (
  parameter p_preescaler = 8, /* clock cycles per bit: clock frequency / baudrate (it should be more than 0) */
  parameter p_data_buffer = 16 /* number of bytes to send */
)(
  input clk,
  input rst, /* synchronous reset */
  input [8*p_data_buffer-1:0] ip_data, /* data to send */
  input i_dv, /* input data valid */
  output o_ready, /* module ready to accept new data */
  output o_tx /* uart transmission line */
);

localparam lpw_preescaler_counter = (p_preescaler > 1) ? $clog2(p_preescaler) : 1;
localparam lp_max_data_bit = (p_data_buffer*8) - 1;

localparam st_idle = 3'd0;
localparam st_start = 3'd1;
localparam st_transmit = 3'd2;
localparam st_stop = 3'd3;

reg [2:0] r3_state; /* FSM state */
reg [8*p_data_buffer-1:0] rp_data; /* complete data */
reg [7:0] r8_byte_send; /* Actual byte sending */

reg [15:0] r16_data_index; /* byte data index */
reg [2:0] r3_nBit; /* bit counter inside a bytes */

/* Baudrate preescaler: held at zero while idle and restarted on every
   start bit, so every bit on the line (start bit included) lasts exactly
   p_preescaler clock cycles no matter when i_dv arrives. A receiver that
   times itself from the start bit edge, like any standard UART, depends
   on that. */
reg [lpw_preescaler_counter-1:0] rp_preescaler_counter;
wire w_uart_tick = (rp_preescaler_counter == (p_preescaler-1));

always@(posedge clk) begin
  if(rst || r3_state == st_idle || w_uart_tick) rp_preescaler_counter <= 0;
  else rp_preescaler_counter <= rp_preescaler_counter + 1;
end

/*

Uart spec:

![image](uart_spec.png)

*/

always@(posedge clk) begin
  if(rst) begin
    r3_state <= st_idle;
    r3_nBit <= 3'd0;
  end
  else begin
    case(r3_state)
      st_idle: begin // Register inputs

        if(i_dv) r3_state <= st_start;
        else r3_state <= st_idle;

        rp_data <= ip_data;
        r16_data_index <= lp_max_data_bit; // Init data index to max bit (send first MSB byte)
        r3_nBit <= 3'd0; // Init byte index to bit 0 (send first bit 0 of byte high)

      end
      st_start: begin // Start bit

        if(w_uart_tick) r3_state <= st_transmit;
        else r3_state <= st_start;

        r8_byte_send <= rp_data[r16_data_index -: 8]; // Get byte

      end
      st_transmit: begin // Transmit a byte

        if(w_uart_tick && r3_nBit == 7) r3_state <= st_stop; // 8 bits send
        else r3_state <= st_transmit;

        r3_nBit <= (w_uart_tick) ? r3_nBit + 1 : r3_nBit; // Bit counter

      end
      st_stop: begin // Stop bit (1 stop bit)

      if(w_uart_tick && r16_data_index == 7) r3_state <= st_idle; // Last byte sended
      else if(w_uart_tick && r16_data_index > 7) r3_state <= st_start; // Continue with next byte
      else r3_state <= st_stop;

      r16_data_index <= (w_uart_tick) ? r16_data_index - 8 : r16_data_index; // Byte counter

      end
      default: r3_state <= st_idle;
    endcase
  end
end

/* TX Output, registered so the pin never sees decoding glitches */
reg r_tx;

always@(posedge clk) begin
  if(rst) r_tx <= 1'b1;
  else r_tx <= (r3_state == st_transmit) ? r8_byte_send[r3_nBit] : ((r3_state == st_start) ? 1'b0 : 1'b1);
end

assign o_tx = r_tx;

/* Ready */
assign o_ready = (r3_state == st_idle) ? 1'b1 : 1'b0;

endmodule
