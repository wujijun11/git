`timescale 1ns/1ps
// 参考使用64位整数除法计算理论结果，不读取RTL除法器内部状态。
module tb_stereo_peak_limiter;
    reg clk=0;
    always #5 clk=~clk;
    reg rn=0,iv=0,ready=1;
    reg signed [44:0] il=0,ir=0;
    wire in_ready,valid,limiting;
    wire signed [23:0] ol,orr;
    wire [16:0] gain;
    stereo_peak_limiter dut(.clk(clk),.rst_n(rn),.in_valid(iv),.in_ready(in_ready),
        .in_left(il),.in_right(ir),.out_valid(valid),.out_ready(ready),.out_left(ol),.out_right(orr),
        .applied_gain_q16(gain),.limiting(limiting));
    longint signed model_gain=65536,expected_left,expected_right;
    integer accepted=0,produced=0,stalls=0,cycles_since_accept=0;
    reg stalled=0;
    reg [47:0] saved;
    function automatic longint signed magnitude(input longint signed x);
        magnitude=x<0?-x:x;
    endfunction
    function automatic longint signed bounded(input longint signed x);
        bounded=x>4194303?4194303:x< -4194303?-4194303:x;
    endfunction
    longint signed peak,need,recovered;
    always @(posedge clk)if(rn)begin
        if(stalled && (!valid || {ol,orr}!==saved))$fatal(1,"limiter output changed under backpressure");
        stalled<=valid && !ready;
        saved<={ol,orr};
        if(valid && !ready)stalls=stalls+1;
        if(iv && in_ready)begin
            peak=magnitude($signed(il))>magnitude($signed(ir))?magnitude($signed(il)):magnitude($signed(ir));
            need=peak<=4194303?65536:(64'sd4194303*65536)/peak;
            if(need<1)need=1;
            recovered=model_gain+64;
            if(recovered>65536)recovered=65536;
            model_gain=need<recovered?need:recovered;
            expected_left=bounded(($signed(il)*model_gain+32768)>>>16);
            expected_right=bounded(($signed(ir)*model_gain+32768)>>>16);
            accepted=accepted+1;
            cycles_since_accept=0;
        end else cycles_since_accept=cycles_since_accept+1;
        if(valid)begin
            if($signed(ol)!=expected_left || $signed(orr)!=expected_right || gain!=model_gain)
                $fatal(1,"limiter arithmetic expected=%0d/%0d gain=%0d actual=%0d/%0d gain=%0d",expected_left,expected_right,model_gain,$signed(ol),$signed(orr),gain);
            if(magnitude($signed(ol))>4194303 || magnitude($signed(orr))>4194303)
                $fatal(1,"limiter exceeded ceiling");
            if(valid && ready)produced=produced+1;
        end
        if(accepted>produced && !valid && cycles_since_accept>24)$fatal(1,"limiter processing latency too long");
    end else stalled<=0;
    task cycles(input integer n);
        repeat(n)@(negedge clk);
    endtask
    task sample(input longint signed l,r,input integer hold_cycles);
        integer before_output;
        begin
            @(negedge clk);
            il=l;ir=r;iv=1;ready=0;
            do @(posedge clk);while(!in_ready);
            @(negedge clk);iv=0;
            wait(valid);
            cycles(hold_cycles);
            before_output=produced;
            ready=1;
            do @(negedge clk);while(produced==before_output);
            cycles(2);
        end
    endtask
    integer i;
    initial begin
        cycles(3);rn=1;
        sample(0,0,0);
        sample(123456,-123456,8);
        sample(4194303,-4194303,0);
        sample(16777216,-8388608,9);
        sample(-536870912,268435456,3);
        for(i=0;i<1100;i=i+1)sample(12345,-24690,0);
        if(gain!=65536)$fatal(1,"gain did not recover to exact unity");
        sample(-64'sd17592186044416,64'sd17592186044415,5);
        rn=0;cycles(3);
        if(valid)$fatal(1,"reset did not cancel held output");
        rn=1;model_gain=65536;
        sample(100,-100,0);
        if(accepted!=produced || stalls<20)$fatal(1,"lost/duplicate output or missing stalls");
        $display("STEREO PEAK LIMITER PASS frames=%0d stalls=%0d arithmetic, stereo linkage, ceiling, unity, release and reset",produced,stalls);
        $finish;
    end
    initial begin #1000000;$fatal(1,"limiter timeout");end
endmodule
