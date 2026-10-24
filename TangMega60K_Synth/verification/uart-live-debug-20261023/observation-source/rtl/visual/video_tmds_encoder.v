`timescale 1ns/1ps
// DVI TMDS encoding, least-significant bit serialized first.
module video_tmds_encoder (
    input wire clk, input wire reset,
    input wire [7:0] data, input wire de, input wire c0,c1,
    output reg [9:0] symbol
);
    reg signed [5:0] disparity;
    reg [8:0] qm;
    reg [9:0] next_symbol;
    reg signed [5:0] next_disparity;
    integer ones, qm_ones, balance, i;
    reg xnor_mode;
    always @* begin
        ones=0;for(i=0;i<8;i=i+1)ones=ones+data[i];
        xnor_mode=(ones>4)||((ones==4)&&!data[0]);
        qm[0]=data[0];
        for(i=1;i<8;i=i+1)qm[i]=qm[i-1]^data[i]^xnor_mode;
        qm[8]=!xnor_mode;
        qm_ones=0;for(i=0;i<8;i=i+1)qm_ones=qm_ones+qm[i];
        balance=2*qm_ones-8;
        next_symbol=0;next_disparity=disparity;
        if(!de)begin
            case({c1,c0})
                2'b00:next_symbol=10'b1101010100;
                2'b01:next_symbol=10'b0010101011;
                2'b10:next_symbol=10'b0101010100;
                2'b11:next_symbol=10'b1010101011;
            endcase
            next_disparity=0;
        end else if(disparity==0||balance==0)begin
            next_symbol={!qm[8],qm[8],qm[8]?qm[7:0]:~qm[7:0]};
            next_disparity=disparity+(qm[8]?balance:-balance);
        end else if((disparity>0&&balance>0)||(disparity<0&&balance<0))begin
            next_symbol={1'b1,qm[8],~qm[7:0]};
            next_disparity=disparity+(qm[8]?2:0)-balance;
        end else begin
            next_symbol={1'b0,qm[8],qm[7:0]};
            next_disparity=disparity+balance-(qm[8]?0:2);
        end
    end
    always @(posedge clk or posedge reset)begin
        if(reset)begin symbol<=10'b1101010100;disparity<=0;end
        else begin symbol<=next_symbol;disparity<=next_disparity;end
    end
endmodule
