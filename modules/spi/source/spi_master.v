module spi_master #(
	parameter p_prescaler = 25, /* spi clock prescaler */
	parameter p_cpol = 0,	/* clock polarity */
	parameter p_max_data_buffer = 64, /* Max data buffer */
	parameter pw_data_index = 6 /* Width for data index */
)(
	input clk,
	input rst,

	input [p_max_data_buffer-1:0] ip_data, /* parallel data to send */
	input [pw_data_index-1:0] ip_data_count, /* number of bits to send */
	input i_data_valid, /* input data ready to send */
	
	output reg [ p_max_data_buffer-1:0] orp_data, /* parallel data readed */
	output o_data_ready, /* SPI module ready to receive data */

	output reg or_mosi, /* master output, slave input pin */
	input i_miso, /* master input, slave output pin */
	output o_sck /* spi clock pin */
	);

	localparam pw_prescaler = $clog2(p_prescaler); /* Prescaler width */

	localparam st_idle = 3'd0;
	localparam st_data_w = 3'd1;
	localparam st_data_r = 3'd2;

	reg [pw_data_index-1:0] rp_data_index; /* data index */
	reg [p_max_data_buffer-1:0] rp_data_in_hold; /* data to send registered */
	reg [p_max_data_buffer-1:0] rp_data_out_hold; /* data received registered */
	reg [2:0] r3_state; /* spi fsm state */
	reg [pw_prescaler-1:0] rp_half_period_counter; /* half period counter */
	reg [pw_data_index:0] rp_data_count; /* Data count registered */
	reg r_sck; /* spi clock temp */

	assign o_sck = (!p_cpol)? r_sck: ~r_sck;

	assign o_data_ready = ((r3_state == st_idle) && (i_data_valid == 1'b0))? 1'b1: 1'b0;

	always @( posedge clk)
		if(rst) begin
			or_mosi <= 1'b0;
			r_sck <= 1'b0;
			r3_state <= st_idle;
			rp_data_out_hold <= 0;
			rp_data_in_hold <= 0;
			rp_data_count = 0;
		end
		else
			case (r3_state)
				st_idle: begin
					if (i_data_valid) r3_state <= st_data_w;
					else r3_state <= st_idle;

					or_mosi <= 1'b0;
					r_sck <= 1'b0;
					rp_data_out_hold <= ip_data;
					rp_data_index <= 0;
					orp_data <= rp_data_in_hold;
					rp_data_count <= ip_data_count-1;
          rp_half_period_counter <= 0;
				end
				st_data_w: begin
					or_mosi <= rp_data_out_hold[ip_data_count-rp_data_index-1];
					r_sck <= 1'b0;

          if(rp_half_period_counter <= (p_prescaler >> 1)) begin 
            rp_half_period_counter <= rp_half_period_counter + 1;
            r3_state <= st_data_w;
          end
          else begin
            rp_half_period_counter <= 0;
            r3_state <= st_data_r;
          end
				end
				st_data_r: begin
					rp_data_in_hold[ip_data_count-rp_data_index-1] <= i_miso;
					r_sck <= 1'b1;

					rp_data_index <= (rp_half_period_counter == 0) ? rp_data_index + 1 : rp_data_index;

          if(rp_half_period_counter <= (p_prescaler >> 1)) begin 
            rp_half_period_counter <= rp_half_period_counter + 1;
            r3_state <= st_data_r;
          end
          else begin
            rp_half_period_counter <= 0;
            r3_state <= (rp_data_index > rp_data_count) ? st_idle : st_data_w;
          end
				end
			endcase

endmodule
