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

module clark_park_tb();

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

  localparam lp_90_deg = 12'd256; /* 90º */
  localparam lp_120_deg = 12'd1365; /* 120º */
  localparam lp_240_deg = 12'd2730; /* 240º */

  real signal_amplitude = 0.5;

  wire [11:0] w12_angle; /* angle */
  reg signed [15:0] r16_r; /* modulator signal R */
  reg signed [15:0] r16_s; /* modulator signal S */
  reg signed [15:0] r16_t; /* modulator signal T */

  wire [15:0] w16_sine; /* sine */
  wire [15:0] w16_cosine; /* cosine */

  wire signed [15:0] ws16_d; /* d vector */
  wire signed [15:0] ws16_q; /* q vector */

  wire signed [15:0] ws16_a; /* obtained A signal */
  wire signed [15:0] ws16_b; /* obtained B signal */
  wire signed [15:0] ws16_c; /* obtained C signal */

  /**** Clock generation ****/
  initial begin
    clk25 = 1'b0;
    #(`clkcycle/2);
    forever
    #(`clkcycle/2) clk25 = ~clk25;
  end

  /**** Test modules instantiation ****/
  dds dds_inst(
    .clk(clk25), 
    .rst(!resetn), 
    .i12_period(12'd61), /* sinusoidal period -> sin_freq = fclk / (4096 * i12_period) -> i12_period = fclk / (sin_freq * 4096) */
    .or12_angle(w12_angle), /* angle generated */
    .ors16_sin(w16_sine), /* sin signal in format S[16,15] */
    .ors16_cos(w16_cosine) /* cos signal in format S[16,15] */
  );

  clarkpark # (
    .pw_io_width(16), /* total input and output width */
    .pw_io_decimal_width(15), /* input and output decimals width */
    .p_2div3(21845), /* 2/3 fixed point value (0.666 * 2^pw_io_decimal_width) */
    .p_sqrt3div3(18918), /* sqrt(3)/3 fixed point value (0.577 * 2^pw_io_decimal_width) */
    .p_1div3(10922) /* 1/3 fixed point value (0.333 * 2^pw_io_decimal_width) */
  ) clarkpark_inst ( 
    .clk(clk25), 
    .reset(!resetn), 
    .isp_a(r16_r), /* input a signal */
    .isp_b(r16_s), /* input b signal */
    .isp_c(r16_t), /* input c signal */
    .ip_sine(w16_sine), /* angle sine */
    .ip_cosine(w16_cosine), /* angle cosine */
    .osp_d(ws16_d), /* output d signal */
    .osp_q(ws16_q) /* output q signal */
  );

  clarkpark_inv # (
    .pw_io_width(16), /* total input and output width */
    .pw_io_decimal_width(15), /* input and output decimals width */
    .p_sqrt3div2(28377) /* sqrt(3)/2 fixed point value (0.866 * 2^pw_io_decimal_width) */
  ) clarkpark_inv_inst (
    .clk(clk25),
    .reset(!resetn),
    .ip_sine(w16_sine),
    .ip_cosine(w16_cosine),
    .isp_d(ws16_d),
    .isp_q(ws16_q),
    .osp_a(ws16_a),
    .osp_b(ws16_b),
    .osp_c(ws16_c)
  );

  /**** Test flow ****/
  initial begin

    $dumpfile ("clark_park_tb.vcd"); // Change filename as appropriate. 
    $dumpvars();

    $display("[INFO] >> Setting initial conditions.");
    
    /*** Reset management ***/
    reset_task();

    /*** Init test flow ***/
    $display("[INFO] >> Test init");

    /*** Test cases ***/
    fork
      begin: f_timeout
        #(2*`_10ms);
        disable f_check;
      end
      begin: f_check
        while(1) begin
          check_values();
          #(`_1us);
        end
      end
    join
 
    #(`_1us);
    $finish();

  end 

  task check_values;
  begin

    integer flag_a, flag_b, flag_c;
    
    // flag = (ws16_a inside {[$signed(r16_r-50) : $signed(r16_r+50)]}) ? 1 : 0; INSIDE EXPRESSION IS NOT SUPPORTED IN IVERILOG
    
    flag_a = ((ws16_a >= (r16_r - 50)) && (ws16_a <= (r16_r + 50))) ? 1 : 0;
    flag_b = ((ws16_b >= (r16_s - 50)) && (ws16_b <= (r16_s + 50))) ? 1 : 0;
    flag_c = ((ws16_c >= (r16_t - 50)) && (ws16_c <= (r16_t + 50))) ? 1 : 0;

    if (!flag_a) begin
      $error("Obtained %d Expected %d", ws16_a, r16_r);
    end
    if (!flag_b) begin
      $error("Obtained %d Expected %d", ws16_b, r16_s);
    end
    if (!flag_c) begin
      $error("Obtained %d Expected %d", ws16_c, r16_t);
    end

  end
  endtask

  initial begin
  
  r16_r <= 0;
  r16_s <= 0;
  r16_t <= 0;
  
  forever begin
    
    r16_s <= signal_amplitude*$sin((w12_angle)*0.00153398)*32767; //2pi/4096 = 0.00153398
    r16_r <= signal_amplitude*$sin((w12_angle+lp_120_deg)*0.00153398)*32767; //2pi/4096 = 0.00153398
    r16_t <= signal_amplitude*$sin((w12_angle+lp_240_deg)*0.00153398)*32767; //2pi/4096 = 0.00153398
    
    #(`_1us);
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