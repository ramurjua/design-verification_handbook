/**** Global timescale ****/
`timescale 10ns/10ns
`define clkcycle 4

/**** Global definitions ****/
`define _1us 100
`define _10us 1000
`define _100us 10000
`define _1ms 100000
`define _10ms 1000000
`define _100ms 10000000
`define _100ns 10
`define _40ns 4
`define _30ns 3

`define max_test_cases 4

module spi_tb();

  /**** Fixed test signals ****/
  integer fd;
  integer error_counter = 0;
  integer test_count = 0;
  integer i;
  integer flag = 0;
  integer verbose = 0;

  /**** Test signals ****/
  reg clk25;
  reg resetn;

  wire w_miso;
  wire w_mosi;
  wire w_sck;

  /**** Clock generation ****/
  initial begin
    clk25 = 1'b0;
    #(`clkcycle/2);
    forever
    #(`clkcycle/2) clk25 = ~clk25;
  end

  /**** Test modules instantiation ****/
  spi_slave #(
  .p_data_buffer_length(), /* input data buffer length */
  .p_frame_timeout(), /* frame timeout */
  .p_cpol(0) /* clock polarity */
  ) spi_slave (
  .clk(clk25),
  .rst(!resetn),
  .ip_data_out(), /* data to send */
  .ip_data_count(), /* data bit count */
  .op_data_in(), /* data received */
  .o_data_valid(), /* new transaction finished */
  .o_busy(), /* spi interface is busy */
  .o_error(), /* error frame */ 
  .i_sclk(w_sck), /* spi sclk input */
  .i_mosi(w_mosi), /* spi mosi input */
  .o_miso(w_miso), /* spi miso output */
  .i_ce() /* chip enable input */
  );

  spi_master #(
	.p_prescaler(), /* spi clock prescaler */
	.p_cpol(0),	/* clock polarity */
	.p_max_data_buffer(), /* Max data buffer */
	.pw_data_index() /* Width for data index */
  ) spi_master (
  .clk(clk25),
  .rst(!resetn),
	.ip_data(), /* parallel data to send */
	.ip_data_count(), /* number of bits to send */
	.i_data_valid(), /* input data ready to send */
	.orp_data(), /* parallel data readed */
	.o_data_ready(), /* SPI module ready to receive data */
	.or_mosi(w_mosi), /* master output, slave input pin */
	.i_miso(w_miso), /* master input, slave output pin */
	.o_sck(w_sck) /* spi clock pin */
	);


  /**** Test flow ****/
  initial begin

    $dumpfile ("spi_tb.vcd"); // Change filename as appropriate. 
    $dumpvars();

    $display("[INFO] >> Setting initial conditions.");
    
    /*** Reset management ***/
    reset_task();

    /*** Init test flow ***/
    $display("[INFO] >> Test init");
    
   
    /*** Test cases ***/
    

    #(`_1us);
    $finish();

  end


  task reset_task;
  begin
    $info("Resetting module.");
    resetn <= 0;

    $info("Release Reset");
    #(20*`clkcycle);
    resetn <= 1;

  end
  endtask

endmodule
