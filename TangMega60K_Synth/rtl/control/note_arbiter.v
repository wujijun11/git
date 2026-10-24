// A held grant makes the entire payload stable when downstream stalls.
// Inputs pack {on,source[5:0],note[6:0],velocity[6:0],timbre[1:0]}.
module note_arbiter (
    input wire clk,rst_n,input wire [3:0] in_valid,
    output reg [3:0] in_ready,input wire [91:0] in_payload,
    output wire out_valid,input wire out_ready,output wire [22:0] out_payload,
    output wire [1:0] selected
);
    reg [1:0] next,grant;
    reg locked;
    reg [3:0] choice_mask;
    wire [1:0] choice={choice_mask[3] || choice_mask[2],
        choice_mask[3] || choice_mask[1]};
    // A rotating variable index followed by in_valid[choice] made a long
    // valid -> priority -> selected-valid -> ready round trip. Decode the
    // four fixed priority orders directly. When unlocked, any request is
    // sufficient for valid, independently of the payload/grant selection.
    wire request_valid=locked ? in_valid[grant] : |in_valid;
    always @* begin
        case(next)
            2'd0: begin
                if(in_valid[0])choice_mask=4'b0001;
                else if(in_valid[1])choice_mask=4'b0010;
                else if(in_valid[2])choice_mask=4'b0100;
                else if(in_valid[3])choice_mask=4'b1000;
                else choice_mask=4'b0001;
            end
            2'd1: begin
                if(in_valid[1])choice_mask=4'b0010;
                else if(in_valid[2])choice_mask=4'b0100;
                else if(in_valid[3])choice_mask=4'b1000;
                else if(in_valid[0])choice_mask=4'b0001;
                else choice_mask=4'b0010;
            end
            2'd2: begin
                if(in_valid[2])choice_mask=4'b0100;
                else if(in_valid[3])choice_mask=4'b1000;
                else if(in_valid[0])choice_mask=4'b0001;
                else if(in_valid[1])choice_mask=4'b0010;
                else choice_mask=4'b0100;
            end
            default: begin
                if(in_valid[3])choice_mask=4'b1000;
                else if(in_valid[0])choice_mask=4'b0001;
                else if(in_valid[1])choice_mask=4'b0010;
                else if(in_valid[2])choice_mask=4'b0100;
                else choice_mask=4'b1000;
            end
        endcase
        if(locked) begin
            case(grant)
                2'd0:choice_mask=4'b0001;
                2'd1:choice_mask=4'b0010;
                2'd2:choice_mask=4'b0100;
                default:choice_mask=4'b1000;
            endcase
        end
        in_ready=choice_mask & {4{rst_n && request_valid && out_ready}};
    end
    assign selected=choice;
    assign out_valid=rst_n && request_valid;
    assign out_payload=(in_payload[22:0] & {23{choice_mask[0]}}) |
        (in_payload[45:23] & {23{choice_mask[1]}}) |
        (in_payload[68:46] & {23{choice_mask[2]}}) |
        (in_payload[91:69] & {23{choice_mask[3]}});
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin next<=0; grant<=0; locked<=0; end
        else if(out_valid) begin
            if(out_ready) begin locked<=0; next<=choice+1'b1; end
            else begin locked<=1; grant<=choice; end
        end
    end
endmodule
