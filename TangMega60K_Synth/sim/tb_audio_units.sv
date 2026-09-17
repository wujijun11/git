`timescale 1ns/1ps
module tb_audio_units;
    reg test_passed=0;
    reg clk=0,rst_n=0;
    always #10 clk=~clk;
    reg signed [31:0] ml=0,mr=0;
    reg [11:0] gain=2048;
    wire signed [23:0] ol,orr;
    gain_saturator #(.SHIFT(1)) gs(clk,ml,mr,gain,ol,orr);
    reg active=1;
    reg [1:0] timbre=0;
    reg [2:0] stage=1;
    reg [23:0] level=0;
    wire [2:0] ns;
    wire [23:0] nl;
    wire finished;
    adsr env(active,timbre,stage,level,ns,nl,finished);
    reg in_valid=0,out_ready=1,bypass=0;
    reg signed [23:0] il=0,ir=0;
    wire in_ready,out_valid;
    wire signed [23:0] fl,fr;
    audio_fx #(.ENABLE(1),.DELAY_SAMPLES(4)) fx (
        .clk(clk),.rst_n(rst_n),.bypass(bypass),.in_valid(in_valid),.in_ready(in_ready),
        .in_left(il),.in_right(ir),.out_valid(out_valid),.out_ready(out_ready),.out_left(fl),.out_right(fr)
    );
    task check_gain(input integer l,r,g,el,er);
        begin
            @(negedge clk); ml=l; mr=r; gain=g;
            @(posedge clk); #1;
            if(ol!==el || orr!==er) $fatal(1,"gain/saturation got %0d,%0d expected %0d,%0d",ol,orr,el,er);
        end
    endtask
    task fx_sample(input integer l,r,el,er);
        begin
            @(negedge clk); in_valid=1; il=l; ir=r;
            do @(posedge clk); while(!in_ready);
            @(negedge clk); in_valid=0;
            wait(out_valid); #1;
            if(fl!==el || fr!==er) $fatal(1,"delay sample got %0d,%0d expected %0d,%0d",fl,fr,el,er);
            @(posedge clk); @(negedge clk);
        end
    endtask
    integer k;
    reg mix_clear=0,mix_add=0;
    reg signed [15:0] mix_sample=0;
    wire signed [31:0] mix_l,mix_r;
    stereo_mixer #(.PAN_SPREAD(0)) mx (
        .clk(clk),.rst_n(rst_n),.clear(mix_clear),.add(mix_add),.voice_id(6'd0),
        .sample_in(mix_sample),.left_sum(mix_l),.right_sum(mix_r)
    );
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        check_gain(1000,-1000,2048,2000,-2000);
        check_gain(1000,-1000,1024,1000,-1000);
        check_gain(1000,-1000,0,0,0);
        check_gain(10000000,-10000000,4095,8388607,-8388608);
        check_gain(2097088,-2097152,4095,8386304,-8386560);
        // Independently derive exact Attack sample count; test all boundaries.
        level=0; stage=1;
        for(k=0;k<480;k=k+1) begin
            #1;
            if(nl<level || nl>24'h800000) $fatal(1,"attack monotonic/range");
            level=nl; stage=ns;
        end
        #1; if(level!=24'h800000 || stage!=2) $fatal(1,"attack duration");
        for(k=0;k<3840;k=k+1) begin #1; level=nl; stage=ns; end
        #1; if(level!=24'h600000 || stage!=3) $fatal(1,"decay/sustain");
        level=10; stage=4; #1;
        if(nl!=0 || !finished) $fatal(1,"release underflow guard");
        // Worst-case coherent full scale: all 64 voices have the same sign.
        @(negedge clk); mix_clear=1;
        @(negedge clk); mix_clear=0; mix_add=1; mix_sample=32767;
        repeat(64) @(negedge clk); mix_add=0;
        if(mix_l!=2097088 || mix_r!=2097088) $fatal(1,"64 positive mix overflow/last sample");
        mix_clear=1; @(negedge clk); mix_clear=0; mix_add=1; mix_sample=-32768;
        repeat(64) @(negedge clk); mix_add=0;
        if(mix_l!=-2097152 || mix_r!=-2097152) $fatal(1,"64 negative mix overflow");
        // Impulse: dry at 0, wet echo at 4, feedback echo at 8 and 12.
        for(k=0;k<17;k=k+1) begin
            fx_sample(k==0 ? 32768:0,k==0 ? -32768:0,
                k==0 ? 32768 : k==4 ? 8192 : k==8 ? 4096 : k==12 ? 2048 : k==16 ? 1024 :0,
                k==0 ? -32768 : k==4 ? -8192 : k==8 ? -4096 : k==12 ? -2048 : k==16 ? -1024 :0);
        end
        bypass=1;
        fx_sample(8388607,-8388608,8388607,-8388608);
        // Reset must invalidate old delay SRAM contents.
        @(negedge clk); rst_n=0; @(negedge clk); rst_n=1; bypass=0;
        for(k=0;k<8;k=k+1) fx_sample(0,0,0,0);
        $display("AUDIO DSP UNITS PASSED: gain/negative/64-coherent-fullscale/saturation/ADSR/impulse/bypass/reset");
        test_passed=1; $finish;
    end
    initial begin #1000000; $fatal(1,"unit timeout"); end
endmodule
