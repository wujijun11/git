`timescale 1ns/1ps
module tb_ui_tone_overlay;
    reg clk=0;always #5 clk=~clk;
    reg rn=0,prompt=0,iv=0,ready=1;
    reg [1:0] code=0;
    reg signed [23:0] il=0,ir=0;
    wire input_ready,ov;wire signed [23:0] ol,orr;
    ui_tone_overlay dut(.clk(clk),.rst_n(rn),.prompt_valid(prompt),.prompt_code(code),
        .in_valid(iv),.in_ready(input_ready),.in_left(il),.in_right(ir),
        .out_valid(ov),.out_ready(ready),.out_left(ol),.out_right(orr));
    reg stalled=0;reg [47:0] previous;
    reg dry_check=1;integer accepted=0,outputs=0,audible=0,clipped=0;
    reg signed [23:0] expected_l[0:19999],expected_r[0:19999];
    always @(posedge clk)if(rn)begin
        if(stalled && (!ov || {ol,orr}!==previous))$fatal(1,"prompt PCM changed under stall");
        stalled<=ov&&!ready;previous<={ol,orr};
        if(iv&&input_ready)begin expected_l[accepted]=il;expected_r[accepted]=ir;accepted=accepted+1;end
        if(ov&&ready)begin
            if((^ol===1'bx)||(^orr===1'bx))$fatal(1,"prompt PCM unknown");
            if(dry_check && (ol!==expected_l[outputs] || orr!==expected_r[outputs]))
                $fatal(1,"dry PCM scale changed");
            if(ol!=0 || orr!=0)audible=audible+1;
            if(ol==24'sh7fffff || ol==24'sh800000)clipped=clipped+1;
            outputs=outputs+1;
        end
    end else stalled<=0;
    task cycles(input integer n);repeat(n)@(negedge clk);endtask
    task frame(input integer l,r);
        begin
            @(negedge clk);il=l;ir=r;iv=1;
            while(!input_ready)@(negedge clk);
            @(negedge clk);iv=0;
        end
    endtask
    integer k,before_audible;reg [31:0] saved_phase;reg [12:0] saved_age;
    initial begin
        cycles(4);rn=1;
        for(k=0;k<100;k=k+1)frame(k*100-5000,5000-k*100);
        cycles(4);if(outputs!=accepted)$fatal(1,"dry packet lost");
        dry_check=0;prompt=1;code=2;cycles(1);prompt=0;
        for(k=0;k<500;k=k+1)frame(0,0);
        cycles(4);before_audible=audible;
        ready=0;frame(0,0);cycles(4);saved_phase=dut.phase;saved_age=dut.age;
        cycles(50);if(dut.phase!=saved_phase || dut.age!=saved_age)$fatal(1,"oscillator advanced without PCM accept");
        ready=1;
        for(k=0;k<4500;k=k+1)frame(0,0);
        cycles(4);
        if(audible<=before_audible || dut.active || dut.pending || ol!=0 || orr!=0)
            $fatal(1,"prompt did not sound and finish");
        if(clipped!=0)$fatal(1,"quiet prompt clipped");
        // 在接近满幅输入上叠加提示，必须饱和，不能有符号回绕。
        prompt=1;code=0;cycles(1);prompt=0;
        for(k=0;k<5000;k=k+1)frame(8388600,8388600);
        cycles(4);if(clipped==0)$fatal(1,"saturation path not exercised");
        if(outputs!=accepted)$fatal(1,"prompt packet lost/duplicated");
        rn=0;cycles(3);if(ov||dut.active||dut.pending)$fatal(1,"prompt reset failed");
        $display("UI TONE PASS dry scale, generated prompt, frame clock, backpressure, saturation and reset");$finish;
    end
    initial begin #1000000;$fatal(1,"prompt test timeout");end
endmodule
