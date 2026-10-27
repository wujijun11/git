`timescale 1ns/1ps
// 独立64位整数公式校验各档最大相干混音、稳态、重定目标、停顿与复位。
module tb_headroom_smoother;
    reg clk=0;
    always #5 clk=~clk;
    reg rn=0,start=0;
    reg [6:0] count=0;
    reg [2:0] shift=0;
    reg signed [31:0] left=0,right=0;
    wire signed [31:0] out_l,out_r;
    wire [16:0] gain;
    wire guard;
    headroom_smoother dut(.clk(clk),.rst_n(rn),.start(start),.active_count(count),.target_shift(shift),
        .mix_left(left),.mix_right(right),.scaled_left(out_l),.scaled_right(out_r),
        .applied_gain_q10(gain),.peak_guard(guard));
    integer target,reference_gain=1024,previous_target=1024,step=0;
    integer difference,expected_l,expected_r,checks=0,guard_checks=0;
    bit initialized=0;
    longint signed value_l,value_r;
    function integer shift_for(input integer n);
        begin
            if(n==0)shift_for=0;
            else if(n==1)shift_for=6;
            else if(n<=2)shift_for=5;
            else if(n<=4)shift_for=4;
            else if(n<=8)shift_for=3;
            else if(n<=16)shift_for=2;
            else if(n<=32)shift_for=1;
            else shift_for=0;
        end
    endfunction
    function integer bound(input longint signed value);
        begin bound=value>2097088 ? 2097088 : value< -2097152 ? -2097152 : value;
        end
    endfunction
    task frame(input integer n,input integer l,r);
        begin
            @(negedge clk);
            count=n;
            shift=shift_for(n);
            left=l;
            right=r;
            start=1;
            target=1024*(2**shift_for(n));
            difference=target>reference_gain ? target-reference_gain : reference_gain-target;
            if(target!=previous_target)step=(difference+63)/64;
            if(n==0)begin reference_gain=1024;
            previous_target=1024;
            step=0;
            initialized=0;
            end
            else begin
                if(!initialized)reference_gain=target;
                else if(reference_gain<target)reference_gain=reference_gain+step>target ? target : reference_gain+step;
                else if(reference_gain>target)reference_gain=reference_gain-step<target ? target : reference_gain-step;
                initialized=1;
                previous_target=target;
            end
            value_l=n==0 ? 0 : (longint'(l)*reference_gain+512)>>>10;
            value_r=n==0 ? 0 : (longint'(r)*reference_gain+512)>>>10;
            expected_l=bound(value_l);
            expected_r=bound(value_r);
            @(negedge clk);
            start=0;
            // 增益寄存与乘积各一拍，与音源V_MIX/V_WRITE对应。
            @(negedge clk);
            if(gain!==reference_gain || out_l!==expected_l || out_r!==expected_r)
                $fatal(1,"arithmetic n=%0d gain=%0d/%0d left=%0d/%0d",n,gain,reference_gain,out_l,expected_l);
            if(guard!==(value_l!=expected_l || value_r!=expected_r))$fatal(1,"guard mismatch");
            if(guard)guard_checks=guard_checks+1;
            checks=checks+1;
            count=0;
            left=32'sh7fffffff;
            right= -32'sh7fffffff;
            repeat(3)@(negedge clk);
            if(gain!==reference_gain || out_l!==expected_l || out_r!==expected_r)$fatal(1,"advanced without start");
        end
    endtask
    integer n,k;
    initial begin
        repeat(4)@(negedge clk);
        rn=1;
        frame(1,32767,-32768);
        if(gain!=65536)$fatal(1,"first note scale changed");
        for(n=2;n<=64;n=n+1)begin
            repeat(65)frame(n,n*32767,-n*32768);
            if(gain!=1024*(2**shift_for(n)))$fatal(1,"steady scale changed n=%0d",n);
        end
        for(n=63;n>=1;n=n-1)begin
            repeat(65)frame(n,n*32767,-n*32768);
            if(gain!=1024*(2**shift_for(n)))$fatal(1,"upward steady gain changed");
        end
        for(k=0;k<30;k=k+1)begin frame(2,24000,-24000);
        frame(33,-100000,100000);
        frame(1,12000,-12000);
        end
        frame(0,123456,-123456);
        frame(1,25000,-25000);
        if(gain!=65536)$fatal(1,"silence did not rearm");
        rn=0;
        @(negedge clk);
        if(out_l || out_r || guard)$fatal(1,"reset did not mask stale product");
        if(guard_checks<30 || checks<8000)$fatal(1,"missing coverage");
        $display("HEADROOM SMOOTHER PASS arithmetic=%0d guard=%0d counts1..64, steady scale, retarget, stall and reset",checks,guard_checks);
        $finish;
    end
    initial begin #1000000;
    $fatal(1,"unit timeout");
    end
endmodule
