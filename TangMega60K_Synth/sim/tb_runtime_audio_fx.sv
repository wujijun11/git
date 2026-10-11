`timescale 1ns/1ps
module tb_runtime_audio_fx;
    reg clk=0;always #5 clk=~clk;reg rn=0,iv=0,ready=0;reg [1:0] mode=0;
    reg signed [23:0] l=0,r=0;wire ir,ov;wire signed [23:0] ol,orr;
    runtime_audio_fx #(.HIST_SIZE(64),.HIST_AW(6),.DELAY_LENGTH(8),.CHORUS_BASE(4),
        .CHORUS_DEPTH(4),.COMB0(7),.COMB1(11),.COMB2(13),.COMB3(17),.AP0(3),.AP1(5)) dut(
        .clk(clk),.rst_n(rn),.mode(mode),.in_valid(iv),.in_ready(ir),.in_left(l),.in_right(r),
        .out_valid(ov),.out_ready(ready),.out_left(ol),.out_right(orr));
    integer cycles,nonzero;reg signed [23:0] got_l,got_r;
    task sample(input signed [23:0] x,input signed [23:0] y);
        begin @(negedge clk);while(!ir)@(negedge clk);iv=1;l=x;r=y;
            @(negedge clk);iv=0;cycles=0;
            while(!ov)begin @(negedge clk);cycles=cycles+1;if(cycles>5)$fatal(1,"fx too slow");end
            got_l=ol;got_r=orr;
            if($isunknown({ol,orr}))$fatal(1,"uninitialized history");
            repeat(3)begin @(negedge clk);if(ir || !ov || ol!==got_l || orr!==got_r)$fatal(1,"stall changed");end
            ready=1;@(negedge clk);ready=0;
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rn=1;
        sample(24'sd123456,-24'sd234567);if(got_l!=123456 || got_r!=-234567)$fatal(1,"dry not exact");
        mode=1;sample(0,0);sample(1048576,-1048576);
        for(integer k=1;k<=16;k=k+1) begin
            sample(0,0);
            if(k==8 && (got_l!=524288 || got_r!=-524288))$fatal(1,"first echo %d",got_l);
            if(k==16 && (got_l!=262144 || got_r!=-262144))$fatal(1,"feedback echo");
            if(k!=8 && k!=16 && got_l!=0)$fatal(1,"wrong echo lag");
        end
        mode=0;sample(0,0);mode=1;sample(0,0);
        repeat(18)begin sample(0,0);if(got_l!=0)$fatal(1,"history leaked across mode");end
        sample(8388607,-8388608);repeat(7)sample(0,0);
        sample(8388607,-8388608);if(got_l!=8388607 || got_r!=-8388608)$fatal(1,"saturation");
        mode=3;sample(0,0);sample(1048576,0);
        repeat(3)begin sample(0,0);if(got_l!=0)$fatal(1,"chorus early");end
        sample(0,0);if(got_l!=524288)$fatal(1,"chorus delayed voice");
        // A ramp identifies the delayed sample independently of the dry input.
        // More than 4096 accepted frames exercise modulation and RAM wrap.
        for(integer k=0;k<5000;k=k+1)begin
            sample(k*1024,-k*1024);
            if(k>64 && got_l!=k*1024+(k-4-((10+2*k)/8192))*512)
                $fatal(1,"chorus modulation/wrap k=%d value=%d",k,got_l);
        end
        mode=2;sample(0,0);sample(1048576,1048576);nonzero=0;
        for(integer k=1;k<70;k=k+1)begin
            sample(0,0);if(got_l!=0 || got_r!=0)nonzero=nonzero+1;
            if(k<7 && got_l!=0)$fatal(1,"reverb guard");
        end
        if(nonzero<10)$fatal(1,"missing reverb tail");
        rn=0;@(negedge clk);rn=1;
        repeat(80)begin sample(0,0);if(got_l!=0 || got_r!=0)$fatal(1,"reset stale tail");end
        $display("RUNTIME AUDIO FX PASS tail_frames=%0d",nonzero);$finish;
    end
    initial begin #2000000;$fatal(1,"timeout");end
endmodule
