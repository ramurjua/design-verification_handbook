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

module uart_tb();

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

  wire w_tx;
  wire w_new_data_rcv;
  wire [31:0] w32_rcv_data;

  reg r_new_data_send;
  reg [31:0] r31_send_data;

  /**** Clock generation ****/
  initial begin
    clk25 = 1'b0;
    #(`clkcycle/2);
    forever
    #(`clkcycle/2) clk25 = ~clk25;
  end

  /**** Test modules instantiation ****/
  uart_tx # (
    .p_preescaler(4), /* clock preescaler to set baudrate */
    .p_data_buffer(4) /* number of bytes to send */
  ) uart_tx (
    .clk(clk25), 
    .rst(!resetn), /* synchronous reset */
    .ip_data(r31_send_data), /* data to send */
    .i_dv(r_new_data_send), /* input data valid */
    .o_ready(), /* module ready to accept new data */
    .o_tx(w_tx) /* uart transmission line */
  );

  uart_rx #(
	  .p_preescaler(4), /* Prescaler for baudrate */
	  .p_data_buffer(4) /* Indicates number of bytes to receive */
  ) uart_rx (
	  .clk(clk25), /* Input clock */
	  .rst(!resetn), /* Input reset */
	  .i_rx(w_tx),	/* Input rx pin */
    .orp_data(w32_rcv_data),	/* Parallel data port */
    .or_dv(w_new_data_rcv) /* New data available in data port */ 
	);

  /**** Test flow ****/
  initial begin

    $dumpfile ("uart_tb.vcd"); // Change filename as appropriate. 
    $dumpvars();

    $display("[INFO] >> Setting initial conditions.");
    
    /*** Reset management ***/
    reset_task();

    /*** Init test flow ***/
    $display("[INFO] >> Test init");
    r_new_data_send <= 1'b0;
   
    /*** Test cases ***/
    repeat(10) begin
      packet_send();
      #(`_10us);
    end

    #(`_1us);
    $finish();

  end

  task packet_send;
  begin

    r_new_data_send <= 1'b1;
    r31_send_data <= $urandom();

    #(`clkcycle);
    r_new_data_send <= 1'b0;

    fork
      begin: f_timeout
        #(`_1ms);
        $error("[ERROR]: No data received");
        disable f_ok;
      end
      begin: f_ok
        @(posedge w_new_data_rcv);
        if(w32_rcv_data != r31_send_data) $error("[ERROR]: Sended data %h - Received data %h", r31_send_data, w32_rcv_data);
        else $display("[OK]: Sended data %h - Received data %h", r31_send_data, w32_rcv_data);

        disable f_timeout;
      end
    join

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
