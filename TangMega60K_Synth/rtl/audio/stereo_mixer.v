// Full 32-bit accumulators. Pan is deterministic per voice (no V2 pan field).
module stereo_mixer #(parameter PAN_SPREAD=1) (
    input wire clk, rst_n, clear, add,
    input wire [5:0] voice_id,
    input wire signed [15:0] sample_in,
    output reg signed [31:0] left_sum, right_sum
);
    wire signed [31:0] x={{16{sample_in[15]}},sample_in};
    wire signed [31:0] three_x=x+(x<<<1);
    wire signed [31:0] strong=(three_x+32'sd2)>>>2;
    wire signed [31:0] weak=(x+32'sd2)>>>2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin left_sum<=0; right_sum<=0; end
        else if (clear) begin left_sum<=0; right_sum<=0; end
        else if (add) begin
            left_sum<=left_sum+(!PAN_SPREAD ? x : (voice_id[0] ? weak : strong));
            right_sum<=right_sum+(!PAN_SPREAD ? x : (voice_id[0] ? strong : weak));
        end
    end
endmodule
