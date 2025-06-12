module clarkpark # (
  parameter pw_io_width = 16, /* total input and output width */
  parameter pw_io_decimal_width = 15, /* input and output decimals width */
  parameter p_2div3 = 21845, /* 2/3 fixed point value (0.666 * 2^pw_io_decimal_width) */
  parameter p_sqrt3div3 = 18918, /* sqrt(3)/3 fixed point value (0.577 * 2^pw_io_decimal_width) */
  parameter p_1div3 = 10922 /* 1/3 fixed point value (0.333 * 2^pw_io_decimal_width) */
)( 
  input clk, 
  input reset, 

  input signed [pw_io_width-1:0] isp_a, /* input a signal */
  input signed [pw_io_width-1:0] isp_b, /* input b signal */
  input signed [pw_io_width-1:0] isp_c, /* input c signal */

  input [pw_io_width-1:0] ip_sine, /* angle sine */
  input [pw_io_width-1:0] ip_cosine, /* angle cosine */

  output signed [pw_io_width-1:0] osp_d, /* output d signal */
  output signed [pw_io_width-1:0] osp_q /* output q signal */
);

/* 

Amplitud invariant Clark transformation:

\begin{bmatrix} Valfa \\ Vbeta \end{bmatrix} = 2/3 \begin{pmatrix} 1 & -1/2  & -1/2  \\ 0 & \sqrt{3}/2  & -\sqrt{3}/2 \end{pmatrix} \cdot \begin{bmatrix} Va \\ Vb \\ Vc \end{bmatrix}

*/

wire signed [pw_io_width-1:0] wsp_alpha; /* alpha signal, output of clark transformation */
wire signed [pw_io_width-1:0] wsp_beta; /* beta signal, output of clark transformation */

reg signed [pw_io_width*2-1:0] rsp_alpha_pc; /* alpha signal precision complete */
reg signed [pw_io_width*2-1:0] rsp_beta_pc; /* beta signal precision complete */

always@(posedge clk) begin
  if(reset) begin
    rsp_alpha_pc <= 0;
    rsp_beta_pc <= 0;
  end
  else begin
    rsp_alpha_pc <= ((isp_a * p_2div3) - (p_1div3 * (isp_b + isp_c)));
		rsp_beta_pc  <= p_sqrt3div3 * (isp_b - isp_c);
  end
end

assign wsp_alpha = rsp_alpha_pc >>>(pw_io_decimal_width); 
assign wsp_beta = rsp_beta_pc >>>(pw_io_decimal_width);

/* 

Park Transformation:

\begin{bmatrix} Vd\\ Vq\end{bmatrix} = \begin{pmatrix} cos(\Theta) & sin(\Theta)   \\ -sin(\Theta) & cos(\Theta) \end{pmatrix} \cdot \begin{bmatrix} Valfa \\ Vbeta \end{bmatrix} 

*/

reg signed [((2*pw_io_width)-1):0] rsp_alpha_cos; /* alpha * cos mult */
reg signed [((2*pw_io_width)-1):0] rsp_alpha_sin; /* alpha * sin mult */
reg signed [((2*pw_io_width)-1):0] rsp_beta_cos; /* beta * cos mult */
reg signed [((2*pw_io_width)-1):0] rsp_beta_sin; /* beta * sin mult */

reg signed [pw_io_width*2-1:0] rsp_d_pc; /* d signal precision complete */
reg signed [pw_io_width*2-1:0] rsp_q_pc; /* q signal precision complete */

always @(posedge clk) 
  if (reset) begin 
    rsp_alpha_cos <= 0;
    rsp_alpha_sin <= 0;
    rsp_beta_cos <= 0;
    rsp_beta_sin <= 0;
  end 
  else begin 
    rsp_alpha_cos <= $signed({{pw_io_width{wsp_alpha[pw_io_width-1]}}, wsp_alpha} * {{pw_io_width{ip_cosine[pw_io_width-1]}}, ip_cosine});
    rsp_alpha_sin <= $signed({{pw_io_width{wsp_alpha[pw_io_width-1]}}, wsp_alpha} * {{pw_io_width{ip_sine[pw_io_width-1]}}, ip_sine});
    rsp_beta_cos <= $signed({{pw_io_width{wsp_beta[pw_io_width-1]}}, wsp_beta} * {{pw_io_width{ip_cosine[pw_io_width-1]}}, ip_cosine});
    rsp_beta_sin <= $signed({{pw_io_width{wsp_beta[pw_io_width-1]}}, wsp_beta} * {{pw_io_width{ip_sine[pw_io_width-1]}}, ip_sine});
  end

always@(posedge clk) begin
  if(reset) begin
    rsp_d_pc <= 0;
    rsp_q_pc <= 0;
  end
  else begin
    rsp_d_pc <= $signed(rsp_alpha_cos + rsp_beta_sin);
		rsp_q_pc <= $signed(rsp_beta_cos - rsp_alpha_sin);
  end
end

assign osp_d = rsp_d_pc >>> pw_io_decimal_width;
assign osp_q = rsp_q_pc >>> pw_io_decimal_width;

endmodule