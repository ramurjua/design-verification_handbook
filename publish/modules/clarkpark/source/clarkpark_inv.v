module clarkpark_inv # (
  parameter pw_io_width = 16, /* total input and output width */
  parameter pw_io_decimal_width = 15, /* input and output decimals width */
  parameter p_sqrt3div2 = 28377 /* sqrt(3)/2 fixed point value (0.866 * 2^pw_io_decimal_width) */
)( 
  input clk, 
  input reset, 
  
  input [pw_io_width-1:0] ip_sine, /* angle sine */
  input [pw_io_width-1:0] ip_cosine, /* angle cosine */

  input signed [pw_io_width-1:0] isp_d, /* input d signal */
  input signed [pw_io_width-1:0] isp_q, /* input q signal */

  output signed [pw_io_width-1:0] osp_a, /* output a signal */
  output signed [pw_io_width-1:0] osp_b, /* output b signal */
  output signed [pw_io_width-1:0] osp_c /* output c signal */
);

/* 

Park inverse transformation:

\begin{bmatrix} Valfa\\ Vbeta\end{bmatrix} = \begin{pmatrix} cos(\Theta) & -sin(\Theta)   \\sin(\Theta) & cos(\Theta) \end{pmatrix} \cdot \begin{bmatrix} Vd \\ Vq \end{bmatrix} 

*/

reg signed [((2*pw_io_width)-1):0] rsp_vd_cos; /* vd * cos mult */
reg signed [((2*pw_io_width)-1):0] rsp_vd_sin; /* vd * sin mult */
reg signed [((2*pw_io_width)-1):0] rsp_vq_cos; /* vq * cos mult */
reg signed [((2*pw_io_width)-1):0] rsp_vq_sin; /* vq * sin mult */

reg signed [pw_io_width*2-1:0] rsp_alpha_pc; /* alpha signal precision complete */
reg signed [pw_io_width*2-1:0] rsp_beta_pc; /* beta signal precision complete */

wire signed [pw_io_width-1:0] wsp_alpha; /* alpha signal, output of park inverse transformation */
wire signed [pw_io_width-1:0] wsp_beta; /* beta signal, output of park inverse transformation */

always @(posedge clk) 
  if (reset) begin 
    rsp_vd_cos <= 0;
    rsp_vd_sin <= 0;
    rsp_vq_cos <= 0;
    rsp_vq_sin <= 0;
  end 
  else begin 
    rsp_vd_cos <= $signed({{pw_io_decimal_width{isp_d[pw_io_width-1]}}, isp_d} * {{pw_io_decimal_width{ip_cosine[pw_io_width-1]}}, ip_cosine});
    rsp_vd_sin <= $signed({{pw_io_decimal_width{isp_d[pw_io_width-1]}}, isp_d} * {{pw_io_decimal_width{ip_sine[pw_io_width-1]}}, ip_sine});
    rsp_vq_cos <= $signed({{pw_io_decimal_width{isp_q[pw_io_width-1]}}, isp_q} * {{pw_io_decimal_width{ip_cosine[pw_io_width-1]}}, ip_cosine});
    rsp_vq_sin <= $signed({{pw_io_decimal_width{isp_q[pw_io_width-1]}}, isp_q} * {{pw_io_decimal_width{ip_sine[pw_io_width-1]}}, ip_sine});
  end

always@(posedge clk) begin
  if(reset) begin
    rsp_alpha_pc <= 0;
    rsp_beta_pc <= 0;
  end
  else begin
    rsp_alpha_pc <= $signed(rsp_vd_cos - rsp_vq_sin);
		rsp_beta_pc <= $signed(rsp_vd_sin + rsp_vq_cos);
  end
end

assign wsp_alpha = rsp_alpha_pc >>> pw_io_decimal_width;
assign wsp_beta = rsp_beta_pc >>> pw_io_decimal_width;

/* 

Clark inverse transformation:

\begin{pmatrix} Va \\ Vb \\ Vc \end{pmatrix} = \begin{pmatrix} 1 & 0 \\ -1/2 & \sqrt{3}/2 \\ -1/2 & -\sqrt{3}/2 \end{pmatrix} \cdot \begin{pmatrix} Valfa \\ Vbeta \end{pmatrix}

*/

reg signed [pw_io_width+pw_io_decimal_width-1:0] rp_beta_sqrt3div2_pc; /* beta * sqrt3div2 mult */
reg signed [pw_io_width-1:0] rp_alpha_reg; /* alpha registered (equal delays with beta) */
wire signed [pw_io_width-1:0] wp_beta_sqrt3div2;
wire signed [pw_io_width-1:0] wp_alpha_div2;

always @(posedge clk)
  if (reset) begin
    rp_beta_sqrt3div2_pc <= 0;
    rp_alpha_reg <= 0;
  end
  else begin
    rp_alpha_reg <= wsp_alpha;
    rp_beta_sqrt3div2_pc <= $signed(p_sqrt3div2 * {{pw_io_width{wsp_beta[pw_io_width-1]}}, wsp_beta});
  end

assign wp_beta_sqrt3div2 = rp_beta_sqrt3div2_pc >>> pw_io_decimal_width;
assign wp_alpha_div2 = rp_alpha_reg>>>1;

assign osp_a = $signed(rp_alpha_reg);
assign osp_b = $signed(-wp_alpha_div2[(pw_io_width-1)-:pw_io_width] + wp_beta_sqrt3div2);
assign osp_c = $signed(-wp_alpha_div2[(pw_io_width-1)-:pw_io_width] - wp_beta_sqrt3div2);

endmodule