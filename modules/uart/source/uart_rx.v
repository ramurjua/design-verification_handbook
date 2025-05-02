module uart_rx # (
  parameter p_preescaler = 8, /* clock preescaler to set baudrate */
  parameter p_data_buffer = 16 /* number of bytes to receive */
)(
  input clk, 
  input rst, /* synchronous reset */
  input i_rx, /* uart reception line */
  output reg [8*p_data_buffer-1:0] orp_data, /* data received */
  output reg or_dv /* output data valid */
);

localparam lpw_preescaler_counter = $clog2(p_preescaler);
localparam lp_max_data_bit = (p_data_buffer*8) - 1;

reg [lpw_preescaler_counter-1:0] rp_preescaler_counter;
reg r_uart_tick;

/* Baudrate preescaler */
always@(posedge clk) begin
  if(rst) begin
    rp_preescaler_counter <= 0;
    r_uart_tick <= 1'b0;
  end
  else begin
    if(rp_preescaler_counter < (p_preescaler-1)) begin
      rp_preescaler_counter <= rp_preescaler_counter + 1;
      r_uart_tick <= 1'b0;
    end
    else begin
      rp_preescaler_counter <= 0;
      r_uart_tick <= 1'b1;
    end
  end
end

localparam st_idle = 3'd0;
localparam st_start = 3'd1;
localparam st_receive = 3'd2;
localparam st_stop = 3'd3;
localparam st_next_byte = 3'd4;
localparam st_end = 3'd5;

reg [2:0] r3_state; /* FSM state */
reg [8*p_data_buffer-1:0] rp_data; /* complete data */
reg [7:0] r8_byte_rcv; /* Actual byte sending */

reg [15:0] r16_data_index; /* byte data index */
reg [2:0] r3_nBit; /* bit counter inside a bytes */

always@(posedge clk) begin
  if(rst) begin
    r3_state <= st_idle;
    r3_nBit <= 3'd0;
    or_dv <= 1'b0;
  end
  else begin
    case(r3_state)
      st_idle: begin // start bit
        
        if(i_rx == 1'b0) r3_state <= st_start;
        else r3_state <= st_idle;

        r16_data_index <= lp_max_data_bit;
        r3_nBit <= 0;
        or_dv <= 1'b0;
      end
      st_start: begin 
        
        if(r_uart_tick) r3_state <= st_receive;
        else r3_state <= st_start;

      end
      st_receive: begin
        
        if(r_uart_tick && r3_nBit == 7) r3_state <= st_stop;
        else r3_state <= st_receive;

        r8_byte_rcv[r3_nBit] <= i_rx;
        r3_nBit <= (r_uart_tick) ? r3_nBit + 1 : r3_nBit; // Bit counter

      end
      st_stop: begin
        
        if(r_uart_tick && r16_data_index == 7) r3_state <= st_end;
        else if (r_uart_tick && r16_data_index > 7) r3_state <= st_next_byte;
        else r3_state <= st_stop;

        r16_data_index <= (r_uart_tick) ? r16_data_index - 8 : r16_data_index; // Byte counter
        rp_data[r16_data_index -: 8] <= r8_byte_rcv;

      end
      st_next_byte: begin
        
        if(i_rx == 1'b0) r3_state <= st_start;
        else r3_state <= st_next_byte;

      end
      st_end: begin

        orp_data <= rp_data;
        or_dv <= 1'b1;

        r3_state <= st_idle;

      end
    endcase
  end
end


endmodule