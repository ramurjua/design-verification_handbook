module spi_slave #(
  parameter p_data_buffer_length = 32, /* input data buffer length */
  parameter p_width_buffer_length = $clog2(p_data_buffer_length)+1, /* input data buffer width */
  parameter p_cpol = 0 /* clock polarity */
)(
  input clk,
  input rst,

  input [p_data_buffer_length-1:0] ip_data_out, /* data to send */
  input [p_width_buffer_length-1:0] ip_data_count, /* data bit count */

  output reg [p_data_buffer_length-1:0] op_data_in, /* data received */
  output o_data_valid, /* new transaction finished */

  output o_busy, /* spi interface is busy */
  
  input i_sclk, /* spi sclk input */
  input i_mosi, /* spi mosi input */
  output reg or_miso /* spi miso output */
);

  localparam lp_index_width = $clog2(p_data_buffer_length)+1; /* index width */

  wire [1:0] w2_sck_end_edge; /* detect idle sck state (CPOL = 0 or CPOL = 1) */
  wire [1:0] w2_read_edge; /* reading edge */
  wire [1:0] w2_write_edge; /* writing edge */

  reg [1:0] r2_spi_state; /* state for spi transaction */
  reg [p_data_buffer_length-1:0] rp_data_out; /* registered data received */
  reg [1:0] r2_clock_edge_detector; /* clock edge detector */
  reg [lp_index_width-1:0] rp_data_index; /* data index */

  assign w2_sck_end_edge = (p_cpol) ? 2'b01 : 2'b10;
  assign w2_read_edge = (p_cpol) ? 2'b10 : 2'b01;
  assign w2_write_edge = (p_cpol) ? 2'b01 : 2'b10;

  always @(posedge clk)
    if (rst)
      r2_clock_edge_detector <= 2'b00;
    else
      r2_clock_edge_detector <= {r2_clock_edge_detector[0], i_sclk};

  always @(posedge clk)
    if (rst) begin
      r2_spi_state <= 2'd0;
      rp_data_out <= {p_data_buffer_length{1'b0}};
      op_data_in <= {p_data_buffer_length{1'b0}};
      rp_data_index <= ip_data_count - 1;
      or_miso <= 1'b0;
    end
    else
    begin
      case(r2_spi_state)
      2'b00: begin
        r2_spi_state <= (^r2_clock_edge_detector)? 2'b01: 2'b00;

        rp_data_out <= ip_data_out;
        or_miso <= rp_data_out[p_data_buffer_length-1];

        rp_data_index <= rp_data_index;
        op_data_in[rp_data_index] <= (r2_clock_edge_detector == w2_read_edge)? i_mosi: op_data_in[rp_data_index]; 
      end

      2'b01: begin
        r2_spi_state <= (((rp_data_index == 0) && (r2_clock_edge_detector == w2_sck_end_edge)))? 2'b10: 2'b01;
        
        rp_data_index <= (r2_clock_edge_detector == w2_write_edge)? rp_data_index - 1: rp_data_index;
        op_data_in[rp_data_index] <= (r2_clock_edge_detector == w2_read_edge)? i_mosi: op_data_in[rp_data_index];
        
        or_miso <= rp_data_out[rp_data_index];
      end

      2'b10: begin
        
        rp_data_index <= ip_data_count - 1; 
        r2_spi_state <= 2'b00;

      end
      endcase

    end

  assign o_data_valid = (r2_spi_state == 2'b10)? 1'b1: 1'b0;
  assign o_busy = r2_spi_state[0];

endmodule