module dds (
  input clk, 
  input rst, 
  input [11:0] i12_period, /* sinusoidal period -> sin_freq = fclk / (4096 * i12_period) -> i12_period = fclk / (sin_freq * 4096) */
  output reg [11:0] or12_angle, /* angle generated */
  output reg signed [15:0] ors16_sin, /* sin signal in format S[16,15] */
  output reg signed [15:0] ors16_cos /* cos signal in format S[16,15] */
);

reg [11:0] r12_preescaler_counter; /* prescaler to generate valid */
reg r_valid_angle; /* angle increments */

reg signed [15:0] mem_sin [0:4095]; /* sinusoidal mem */
initial $readmemh("sin16.mem", mem_sin);

reg signed [15:0] mem_cos [0:4095]; /* cos mem */
initial $readmemh("cos16.mem", mem_cos);

/* Preescaler angle */
always@(posedge clk) begin
  if(rst) begin
    r12_preescaler_counter <= 12'd0;
    r_valid_angle <= 1'b0;
  end
  else begin
    if(r12_preescaler_counter < (i12_period-1)) begin
      r12_preescaler_counter <= r12_preescaler_counter + 1;
      r_valid_angle <= 1'b0;
    end
    else begin
      r12_preescaler_counter <= 0;
      r_valid_angle <= 1'b1;
    end
  end
end

/* Angle generation */
always@(posedge clk) begin
  if(rst) begin
    or12_angle <= 12'd0;
  end
  else begin
    if(r_valid_angle) or12_angle <= or12_angle + 1;
  end
end

/* Waves geneation */
always @(posedge clk)
  if (rst) begin
    ors16_sin <= 16'd0;
    ors16_cos <= 16'd0;
  end
  else begin
    ors16_sin <= mem_sin[or12_angle];
    ors16_cos <= mem_cos[or12_angle];
  end


endmodule