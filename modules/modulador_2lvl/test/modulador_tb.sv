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

module modulador_tb();

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

  real signal_amplitude = 0.1; // aprox 50 % duty

  localparam lp_90_deg = 12'd256; /* 90º */
  localparam lp_120_deg = 12'd1365; /* 120º */
  localparam lp_240_deg = 12'd2730; /* 240º */

  wire [2:0] w3_pwm;
  reg [11:0] r12_angle; /* angle */
  reg [15:0] r16_modulator_r; /* modulator signal R */
  reg [15:0] r16_modulator_s; /* modulator signal S */
  reg [15:0] r16_modulator_t; /* modulator signal T */

  /**** Clock generation ****/
  initial begin
    clk25 = 1'b0;
    #(`clkcycle/2);
    forever
    #(`clkcycle/2) clk25 = ~clk25;
  end

  /**** Test modules instantiation ****/
  modulador_2lvl dut(
    .clk(clk25),
    .rst(!resetn), 
    .i_on(1'b1), /* transistors on */
    .i_enable_sawtooth(1'b0), /* carrier waveforms selection */
    .i16_period(16'd625), /*  TRIANGULAR: period = fclk / (2 * fsw) - SAWTOOTH: period = fclk / fsw */
    .i16_modulator_r(r16_modulator_r), /* modulator signal R */
    .i16_modulator_s(r16_modulator_s), /* modulator signal S */
    .i16_modulator_t(r16_modulator_t), /* modulator signal T */
    .o3_pwm(w3_pwm) /* pwm output HIGH, phase R - S - T*/
  );

  /**** Test flow ****/
  initial begin

    $dumpfile ("modulador_tb.vcd"); // Change filename as appropriate. 
    $dumpvars();

    $display("[INFO] >> Setting initial conditions.");
    
    /*** Reset management ***/
    reset_task();

    /*** Init test flow ***/
    $display("[INFO] >> Test init");
    
    /*** Test cases ***/
    #(20*`_1ms);
    
    #(`_1us);
    $finish();

  end
  
  initial begin
    
    r16_modulator_r <= 0;
    r16_modulator_s <= 0;
    r16_modulator_t <= 0;
    r12_angle <= 0;//lp_90_deg;
    
    forever begin
      
      r16_modulator_s <= signal_amplitude*$sin((r12_angle)*0.00153398)*32767; //2pi/4096 = 0.00153398
      r16_modulator_r <= signal_amplitude*$sin((r12_angle+lp_120_deg)*0.00153398)*32767; //2pi/4096 = 0.00153398
      r16_modulator_t <= signal_amplitude*$sin((r12_angle+lp_240_deg)*0.00153398)*32767; //2pi/4096 = 0.00153398
      
      r12_angle = r12_angle + 12'd1; 

      #(4*`_1us); // 3 kHz
    end
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