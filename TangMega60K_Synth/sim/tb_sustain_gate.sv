`timescale 1ns/1ps
// 实际命令边界的独立计分板：吞掉的OFF、补发的OFF及反压稳定分别计数。
module tb_sustain_gate;
    parameter integer N=64;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,sustain_enabled=0,in_valid=0,in_on=0,out_ready=1;
    reg [5:0] in_voice=0;
    reg [6:0] in_note=60,in_velocity=100;
    reg [1:0] in_timbre=2;
    wire in_ready,out_valid,out_on;
    wire [5:0] out_voice;
    wire [6:0] out_note,out_velocity,deferred_count;
    wire [1:0] out_timbre;
    wire [N-1:0] deferred_mask;
    sustain_command_gate #(.VOICE_COUNT(N)) dut(.*);
    integer ons=0,offs=0,accepted=0,n;
    integer release_seen[0:N-1];
    reg stalled=0;
    reg [22:0] saved;
    always @(posedge clk)begin
        if(!rst_n)stalled<=0;
        else begin
            if(stalled && (!out_valid || {out_on,out_voice,out_note,out_velocity,out_timbre}!==saved))
                $fatal(1,"sustain output changed during backpressure");
            stalled<=out_valid && !out_ready;
            saved<={out_on,out_voice,out_note,out_velocity,out_timbre};
            if(in_valid && in_ready)accepted=accepted+1;
            if(out_valid && out_ready)begin
                if(out_on)ons=ons+1;
                else begin offs=offs+1;release_seen[out_voice]=release_seen[out_voice]+1;end
            end
            if(deferred_count!=$countones(deferred_mask))$fatal(1,"deferred count mismatch");
        end
    end
    task cycles(input integer count);repeat(count)@(negedge clk);endtask
    task command(input bit on,input integer voice);
        begin
            @(negedge clk);in_valid=1;in_on=on;in_voice=voice;
            do @(posedge clk);while(!in_ready);
            @(negedge clk);in_valid=0;
        end
    endtask
    initial begin
        for(n=0;n<N;n=n+1)release_seen[n]=0;
        cycles(3);rst_n=1;
        command(1,0);command(0,0);
        if(ons!=1 || offs!=1 || deferred_count!=0)$fatal(1,"dry forwarding");
        sustain_enabled=1;
        for(n=0;n<N;n=n+1)command(1,n);
        for(n=0;n<N;n=n+1)command(0,n);
        if(deferred_count!=N || offs!=1)$fatal(1,"pedal did not retain releases");
        out_ready=0;sustain_enabled=0;
        wait(out_valid);cycles(10);
        // 已呈现的OFF在重新开踏板时也不能撤回；其余尚未呈现的音允许被再次接住。
        sustain_enabled=1;cycles(10);out_ready=1;cycles(4);
        if(offs!=2 || deferred_count!=N-1)$fatal(1,"rapid off/on handling");
        sustain_enabled=0;
        wait(deferred_count==0);cycles(4);
        if(offs!=N+1)$fatal(1,"release lost/duplicated");
        for(n=1;n<N;n=n+1)if(release_seen[n]!=1)$fatal(1,"wrong release voice %0d",n);
        sustain_enabled=1;command(0,0);command(0,0);
        if(deferred_count!=1)$fatal(1,"duplicate off not idempotent");
        command(1,0);
        if(deferred_count!=0)$fatal(1,"new ON retained stale release");
        // 在被保留的松键提交前切换踏板，OFF应随后补发一次。
        @(negedge clk);in_valid=1;in_on=0;in_voice=0;
        cycles(1);sustain_enabled=0;
        do @(posedge clk);while(!in_ready);
        @(negedge clk);in_valid=0;
        wait(deferred_count==0 && dut.state==0);cycles(4);
        out_ready=0;in_valid=1;in_on=1;cycles(4);
        rst_n=0;cycles(2);in_valid=0;out_ready=1;rst_n=1;cycles(4);
        if(out_valid || deferred_count!=0)$fatal(1,"reset left pending command");
        $display("SUSTAIN GATE PASS N=%0d ons=%0d offs=%0d accepted=%0d",N,ons,offs,accepted);
        $finish;
    end
    initial begin #5000000;$fatal(1,"sustain gate timeout");end
endmodule
