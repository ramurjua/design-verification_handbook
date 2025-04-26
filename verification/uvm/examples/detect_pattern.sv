module detect_pattern (
    input logic  clk, // clock
    input logic  rstn, // reset
    input logic  i_data, // data input port
    output logic or_dout // detected sequence output port
);

localparam logic  lp_pattern = 4'b1011;

logic [3:0] r4_shift_reg;
logic [1:0] r2_counter;

always_ff @(posedge clk) begin
    if(!rstn) begin
        r4_shift_reg <= 4'd0;
        r2_counter <= 2'd0;
        or_dout <= 1'b0;
    end
    else begin
        r2_counter <= r2_counter + 1;
        r4_shift_reg[r2_counter] <= i_data;
        or_dout <= (r4_shift_reg == lp_pattern); 
    end
end

endmodule