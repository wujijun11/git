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
    reg found;
    reg [1:0] choice;
    integer k,index;
    always @* begin
        found=0; choice=next;
        for(k=0;k<4;k=k+1) begin
            index=(next+k)%4;
            if(!found && in_valid[index]) begin found=1; choice=index; end
        end
        if(locked) choice=grant;
        in_ready=0;
        if(rst_n && in_valid[choice]) in_ready[choice]=out_ready;
    end
    assign selected=choice;
    assign out_valid=rst_n && in_valid[choice];
    assign out_payload=in_payload[choice*23+:23];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin next<=0; grant<=0; locked<=0; end
        else if(out_valid) begin
            if(out_ready) begin locked<=0; next<=choice+1'b1; end
            else begin locked<=1; grant<=choice; end
        end
    end
endmodule
