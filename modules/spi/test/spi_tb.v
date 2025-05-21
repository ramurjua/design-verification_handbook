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

  reg [23:0] r24_data_to_send_master; /* data that master is sendind */
  wire [23:0] w24_data_received_master; /* data that master is receiving */
  reg r_send_data; /* send data */
  wire w_master_ready; /* master ready */

  reg [23:0] r24_data_to_send_slave; /* data that slave is sendind */
  wire [23:0] w24_data_received_slave; /* data that slave is receiving */
  wire w_received_slave; /* new data received in slave */

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
  .ip_data_out(r24_data_to_send_slave), /* data to send */
  .ip_data_count(5'd24), /* data bit count */
  .op_data_in(w24_data_received_slave), /* data received */
  .o_data_valid(w_received_slave), /* new transaction finished */
  .o_busy(), /* spi interface is busy */
  .o_error(), /* error frame */ 
  .i_sclk(w_sck), /* spi sclk input */
  .i_mosi(w_mosi), /* spi mosi input */
  .o_miso(w_miso) /* spi miso output */
  );

  spi_master #(
	.p_prescaler(8), /* spi clock prescaler */
	.p_cpol(0),	/* clock polarity */
	.p_max_data_buffer(32), /* Max data buffer in bits */
	.pw_data_index(5) /* Width for data index */
  ) spi_master (
  .clk(clk25),
  .rst(!resetn),
	.ip_data(r24_data_to_send_master), /* parallel data to send */
	.ip_data_count(5'd24), /* number of bits to send */
	.i_data_valid(r_send_data), /* input data ready to send */
	.orp_data(w24_data_received_master), /* parallel data readed */
	.o_data_ready(w_master_ready), /* SPI module ready to receive data */
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
    r24_data_to_send_master <= 24'd0;
    r_send_data <= 1'b0;
    r24_data_to_send_slave <= 24'd0;
    
    /*** Test cases ***/
    repeat(10) begin
      packet_send();
      #(`_1us);
    end

    #(`_1us);
    $finish();

  end

  task packet_send;
  begin

    $display("Packet send");

    r24_data_to_send_master <= $urandom();
    r24_data_to_send_slave <= $urandom();

    r_send_data <= 1'b1;
    #(`clkcycle);
    r_send_data <= 1'b0;

    fork
      begin: f_transaction
        @(posedge w_received_slave);
        
        if(w_master_ready) $display("Master complete sending");
        else $error("Master not complete sending");
        
        disable f_timeout;
      end
      begin: f_timeout
        #(2*`_10us);
        
        if(w_master_ready) $error("Slave not complete reception");
        else $error("Master not complete sending");
        
        disable f_transaction;
      end
    join

    if(w24_data_received_slave != r24_data_to_send_master) begin
      $error("Received data from slave is different from master sending");
      $display("Slave %d, Master %d", w24_data_received_slave, r24_data_to_send_master);
    end
    if(w24_data_received_master != r24_data_to_send_slave) begin
      $error("Received data from master is different from slave sending");
      $display("Slave %d, Master %d", r24_data_to_send_slave, w24_data_received_master);
    end

  end
  endtask


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
