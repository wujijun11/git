`timescale 1ns/1ps
// 使用原V2分配器，不绕过来源/音高匹配。模拟音源的释放尾音和done反压。
module tb_sustain_allocator;
    parameter integer N=64;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,pedal=0,event_valid=0,event_on=0;
    reg [5:0] event_source=25;
    reg [6:0] event_note=60,event_velocity=100;
    wire event_ready,cmd_valid,cmd_ready,cmd_on;
    wire [5:0] cmd_voice;
    wire [6:0] cmd_note,cmd_velocity,active_count;
    wire [1:0] cmd_timbre;
    wire [N-1:0] active_mask,held_mask,deferred_mask;
    wire full_pulse,ignored_pulse,done_error_pulse;
    reg done_valid=0;wire done_ready;reg [5:0] done_voice=0;
    voice_allocator_v2 #(.VOICE_COUNT(N)) allocator(.clk(clk),.rst_n(rst_n),
        .event_valid(event_valid),.event_ready(event_ready),.event_on(event_on),
        .event_source(event_source),.event_note(event_note),.event_velocity(event_velocity),.event_timbre(2'd2),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_on(cmd_on),.cmd_voice(cmd_voice),
        .cmd_note(cmd_note),.cmd_velocity(cmd_velocity),.cmd_timbre(cmd_timbre),
        .done_valid(done_valid),.done_ready(done_ready),.done_voice(done_voice),
        .active_count(active_count),.active_mask(active_mask),.held_mask(held_mask),
        .full_pulse(full_pulse),.ignored_pulse(ignored_pulse),.done_error_pulse(done_error_pulse));
    wire out_valid,out_on;reg out_ready=1;
    wire [5:0] out_voice;wire [6:0] deferred_count;
    sustain_command_gate #(.VOICE_COUNT(N)) gate(.clk(clk),.rst_n(rst_n),.sustain_enabled(pedal),
        .in_valid(cmd_valid),.in_ready(cmd_ready),.in_on(cmd_on),.in_voice(cmd_voice),
        .in_note(cmd_note),.in_velocity(cmd_velocity),.in_timbre(cmd_timbre),
        .out_valid(out_valid),.out_ready(out_ready),.out_on(out_on),.out_voice(out_voice),
        .out_note(),.out_velocity(),.out_timbre(),.deferred_mask(deferred_mask),.deferred_count(deferred_count));
    reg [N-1:0] engine_active=0,engine_held=0;
    integer tail[0:N-1];
    integer cycle=0,n,ons=0,offs=0,fulls=0,errors=0;
    always @(posedge clk)if(rst_n)begin
        cycle=cycle+1;
        if(full_pulse)fulls=fulls+1;
        if(done_error_pulse)errors=errors+1;
        for(integer k=0;k<N;k=k+1)if(tail[k]>0)tail[k]=tail[k]-1;
        if(done_valid && done_ready)begin engine_active[done_voice]=0;done_valid<=0;end
        if(!done_valid)begin
            for(integer k=N-1;k>=0;k=k-1)
                if(engine_active[k] && !engine_held[k] && tail[k]==0)begin done_valid<=1;done_voice<=k;end
        end
        if(out_valid && out_ready)begin
            if(out_on)begin
                ons=ons+1;engine_active[out_voice]=1;engine_held[out_voice]=1;tail[out_voice]=0;
            end else begin
                if(!engine_active[out_voice] || !engine_held[out_voice])$fatal(1,"duplicate or invalid engine OFF");
                offs=offs+1;engine_held[out_voice]=0;tail[out_voice]=17;
            end
        end
    end
    always @(negedge clk)out_ready=(cycle%7)!=0;
    task cycles(input integer count);repeat(count)@(negedge clk);endtask
    task event_send(input bit on,input integer note);
        begin
            @(negedge clk);event_valid=1;event_on=on;event_note=note;
            do @(posedge clk);while(!event_ready);
            @(negedge clk);event_valid=0;
            wait(allocator.state==0);cycles(2);
        end
    endtask
    initial begin
        for(n=0;n<N;n=n+1)tail[n]=0;
        cycles(3);rst_n=1;pedal=1;
        // 同一来源和音高重新弹奏，在旧声部仍延音时分配新空槽。
        event_send(1,60);event_send(0,60);event_send(1,60);event_send(0,60);
        if(active_count!=2 || deferred_count!=2 || held_mask!=0)$fatal(1,"repeated pitch ownership");
        pedal=0;wait(active_count==0);cycles(3);
        // 填满后松开所有键，全部仍占槽；满载新音被拒绝但通路能继续处理。
        pedal=1;
        for(n=0;n<N;n=n+1)event_send(1,n);
        for(n=0;n<N;n=n+1)event_send(0,n);
        if(active_count!=N || deferred_count!=N || held_mask!=0)$fatal(1,"full sustain count");
        event_send(1,127);
        if(fulls!=1 || active_count!=N)$fatal(1,"full voice policy changed");
        pedal=0;wait(active_count==0);cycles(4);
        // 已松开的音释放，仍按住的另一个音必须保留。
        pedal=1;event_send(1,60);event_send(1,64);event_send(0,60);
        pedal=0;wait(deferred_count==0);cycles(N*4+40);
        if(active_count!=1 || $countones(engine_held)!=1)$fatal(1,"held key killed by pedal-up");
        event_send(0,64);wait(active_count==0);cycles(3);
        if(errors || ons!=offs)$fatal(1,"tail recycle mismatch ons=%0d offs=%0d err=%0d",ons,offs,errors);
        pedal=1;event_send(1,70);event_send(0,70);
        rst_n=0;cycles(3);
        if(active_count || deferred_count || out_valid)$fatal(1,"reset left voices");
        $display("SUSTAIN ALLOCATOR PASS N=%0d ons=%0d offs=%0d full=%0d",N,ons,offs,fulls);
        $finish;
    end
    initial begin #10000000;$fatal(1,"allocator sustain timeout");end
endmodule
