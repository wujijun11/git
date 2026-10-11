`timescale 1ns/1ps
module tb_video_encoder;
    reg clk=0;always #20 clk=~clk;
    reg reset=1,de=0,c0=0,c1=0;reg [7:0] data=0;wire [9:0] symbol;
    video_tmds_encoder dut(.*);
    reg [7:0] qm,decoded;
    integer i,j,ones,transitions,running=0;reg [9:0] ctrl;
    reg [15:0] lfsr=16'hace1;
    task sample;
        begin @(posedge clk);#1;end
    endtask
    initial begin
        sample();reset=0;
        for(i=0;i<16384;i=i+1)begin
            @(negedge clk);de=1;data=i<256?i[7:0]:lfsr[7:0];
            lfsr={lfsr[14:0],lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};sample();
            // Decode the transmitted symbol back to data, independent of the
            // encoder's branch selection and its running-disparity arithmetic.
            qm=symbol[9]?~symbol[7:0]:symbol[7:0];decoded[0]=qm[0];
            for(j=1;j<8;j=j+1)decoded[j]=qm[j]^qm[j-1]^!symbol[8];
            if(decoded!==data)$fatal(1,"TMDS decode %h != %h symbol=%b",decoded,data,symbol);
            ones=0;for(j=0;j<10;j=j+1)ones=ones+symbol[j];running=running+2*ones-10;
            if(running!==$signed(dut.disparity)||running>8||running< -8)$fatal(1,"disparity %0d",running);
            transitions=0;for(j=1;j<8;j=j+1)transitions=transitions+(qm[j]!=qm[j-1]);
            if(transitions>4)$fatal(1,"TMDS excessive transitions");
            if(i%137==0)begin
                @(negedge clk);de=0;c0=(i>>1)&1;c1=(i>>2)&1;sample();
                case({c1,c0})
                    0:ctrl=10'b1101010100;1:ctrl=10'b0010101011;
                    2:ctrl=10'b0101010100;3:ctrl=10'b1010101011;
                endcase
                if(symbol!==ctrl||dut.disparity!==0)$fatal(1,"blanking control or disparity reset");running=0;
            end
        end
        reset=1;sample();if(symbol!==10'b1101010100||dut.disparity!==0)$fatal(1,"encoder reset");
        $display("ALL VIDEO TMDS ENCODER TESTS PASSED (16384 symbols, decode, balance, transitions, controls)");$finish;
    end
endmodule
