// Signed mix * unsigned Q1.11 gain. SHIFT=1 gives 64-voice gain<2 headroom.
module gain_saturator #(parameter SHIFT=1) (
    input wire clk,
    input wire signed [31:0] mix_left, mix_right,
    input wire [11:0] gain,
    output wire signed [23:0] out_left, out_right
);
    reg signed [44:0] product_l,product_r;
    wire signed [44:0] scaled_l=((product_l+45'sd1024)>>>11)<<<SHIFT;
    wire signed [44:0] scaled_r=((product_r+45'sd1024)>>>11)<<<SHIFT;
    function [23:0] sat24;
        input signed [44:0] x;
        begin
            if (x>45'sd8388607) sat24=24'h7fffff;
            else if (x < -45'sd8388608) sat24=24'h800000;
            else sat24=x[23:0];
        end
    endfunction
    always @(posedge clk) begin
        product_l<=mix_left*$signed({1'b0,gain});
        product_r<=mix_right*$signed({1'b0,gain});
    end
    assign out_left=sat24(scaled_l);
    assign out_right=sat24(scaled_r);
endmodule
