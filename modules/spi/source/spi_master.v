module spi_master #(
	parameter p_prescaler = 25, /* spi clock prescaler */
	parameter p_cpol = 0,	/* clock polarity: sck idle level */
	parameter p_max_data_buffer = 64, /* Max data buffer in bits */
	parameter pw_data_index = 6, /* Width for data index */
	parameter p_cpha = 0 /* clock phase: 0 = sample on the first sck edge, 1 = on the second (cpol/cpha 0/0 = mode 0, 1/1 = mode 3) */
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
	output o_sck, /* spi clock pin */
	output o_busy /* 1'b1 whenever a transaction is in progress, for external chip-select framing */
	);

	localparam pw_prescaler = $clog2(p_prescaler); /* Prescaler width */

	/* r_sck is low while mosi is set up and high while miso is sampled. With
	   cpha = 1 that low phase is the first half of each bit, so it has to
	   idle high for the first edge of a transaction to be the set-up edge. */
	localparam lp_sck_idle = (p_cpha != 0) ? 1'b1 : 1'b0;
	localparam lp_sck_invert = ((p_cpol != 0) != (p_cpha != 0)) ? 1'b1 : 1'b0;

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

	assign o_sck = (lp_sck_invert)? ~r_sck: r_sck;

	assign o_data_ready = ((r3_state == st_idle) && (i_data_valid == 1'b0))? 1'b1: 1'b0;

	assign o_busy = (r3_state != st_idle);

	always @( posedge clk)
		if(rst) begin
			or_mosi <= 1'b0;
			r_sck <= lp_sck_idle;
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
					r_sck <= lp_sck_idle;
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
