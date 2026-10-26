// 串行double-dabble：16拍转换16位计数，避免组合除法影响显示时序。
// 超过9999时显示9999。done只脉冲一拍，忙时忽略新的start。
module bin16_to_bcd (
    input wire clk,rst_n,start,input wire [15:0] value,
    output reg done,output reg [15:0] digits
);
    reg busy;reg [4:0] bit_count;reg [31:0] shift;
    reg [31:0] adjusted;integer digit;
    always @* begin
        adjusted=shift;
        for(digit=0;digit<4;digit=digit+1)
            if(shift[16+digit*4 +:4]>=5)
                adjusted[16+digit*4 +:4]=shift[16+digit*4 +:4]+4'd3;
    end
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin busy<=0;bit_count<=0;shift<=0;done<=0;digits<=0;end
        else begin
            done<=0;
            if(start && !busy)begin
                if(value>9999)begin digits<=16'h9999;done<=1;end
                else begin shift<={16'd0,value};bit_count<=0;busy<=1;end
            end else if(busy)begin
                shift<=adjusted<<1;
                if(bit_count==15)begin digits<=adjusted[30:15];busy<=0;done<=1;end
                else bit_count<=bit_count+1'b1;
            end
        end
    end
endmodule
