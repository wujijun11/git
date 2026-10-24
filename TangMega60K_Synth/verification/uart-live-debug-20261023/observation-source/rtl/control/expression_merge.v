// Merge two masked controllers into atomic snapshots. Slider updates do not
// accidentally overwrite the phone's gain/vibrato. Fair arbitration; no drops.
module expression_merge (
    input wire clk,rst_n,
    input wire a_valid,output wire a_ready,input wire [2:0] a_mask,
    input wire [11:0] a_gain,input wire signed [12:0] a_bend,input wire [7:0] a_vibrato,
    input wire b_valid,output wire b_ready,input wire [2:0] b_mask,
    input wire [11:0] b_gain,input wire signed [12:0] b_bend,input wire [7:0] b_vibrato,
    output reg out_valid,input wire out_ready,
    output reg [11:0] out_gain,output reg signed [12:0] out_bend,
    output reg [7:0] out_vibrato
);
    reg turn;
    wire choose_b=b_valid && (!a_valid || turn);
    wire space=rst_n && (!out_valid || out_ready);
    assign a_ready=space && !choose_b;
    assign b_ready=space && choose_b;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            turn<=0; out_valid<=0; out_gain<=2048; out_bend<=0; out_vibrato<=0;
        end else if(space) begin
            out_valid<=a_valid || b_valid;
            if(a_valid || b_valid) begin
                turn<=!choose_b;
                if(choose_b) begin
                    if(b_mask[0]) out_gain<=b_gain;
                    if(b_mask[1]) out_bend<=b_bend;
                    if(b_mask[2]) out_vibrato<=b_vibrato;
                end else begin
                    if(a_mask[0]) out_gain<=a_gain;
                    if(a_mask[1]) out_bend<=a_bend;
                    if(a_mask[2]) out_vibrato<=a_vibrato;
                end
            end
        end
    end
endmodule
