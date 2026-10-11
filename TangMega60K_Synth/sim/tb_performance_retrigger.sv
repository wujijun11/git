`timescale 1ns/1ps
module tb_performance_retrigger;
    reg clk=0; always #5 clk=!clk;
    reg rst_n=0, command_valid=0;
    reg [7:0] command_opcode=0; reg [79:0] command_payload=0;
    wire command_ready; wire [7:0] command_status;
    reg record_valid=0,record_on=0;
    reg [5:0] record_source=25;
    reg [6:0] record_note=60,record_velocity=100;
    reg [1:0] record_timbre=2;
    wire event_valid,event_ready,event_on;
    wire [5:0] event_source; wire [6:0] event_note,event_velocity;
    wire [1:0] event_timbre;
    reg [174:0] key_map_flat=0; reg [1:0] current_timbre=2;
    wire [24:0] guide_mask; wire playing,recording,guide_active,overflow_sticky;
    wire [15:0] record_count,score_position;
    wire record_read_valid; wire [79:0] row_payload;
    reg accept_events=1;
    wire allocator_ready,cmd_valid,cmd_on,done_ready;
    wire [1:0] cmd_voice,cmd_timbre;
    wire [6:0] cmd_note,cmd_velocity;
    wire [2:0] active_count;
    wire [3:0] active_mask,held_mask;
    wire full_pulse;
    assign event_ready=accept_events && allocator_ready;
    performance_controller #(.CLK_HZ(10000),.SCORE_CAPACITY(16),.RECORD_CAPACITY(8)) dut(
        .clk(clk),.rst_n(rst_n),.command_valid(command_valid),.command_ready(command_ready),
        .command_opcode(command_opcode),.command_payload(command_payload),.command_status(command_status),
        .record_valid(record_valid),.record_on(record_on),.record_source(record_source),
        .record_note(record_note),.record_velocity(record_velocity),.record_timbre(record_timbre),
        .event_valid(event_valid),.event_ready(event_ready),.event_on(event_on),
        .event_source(event_source),.event_note(event_note),.event_velocity(event_velocity),.event_timbre(event_timbre),
        .key_map_flat(key_map_flat),.current_timbre(current_timbre),.guide_mask(guide_mask),
        .playing(playing),.recording(recording),.guide_active(guide_active),.overflow_sticky(overflow_sticky),
        .record_count(record_count),.score_position(score_position),.record_read_index(16'd0),
        .record_read_valid(record_read_valid),.row_payload(row_payload));
    // Real allocator ownership is checked independently of the controller's
    // held mask. Release tails intentionally stay allocated: same-pitch
    // retriggers must therefore work even with all four slots occupied.
    voice_allocator_v2 #(.VOICE_COUNT(4),.ID_WIDTH(2)) allocator(
        .clk(clk),.rst_n(rst_n),.event_valid(event_valid && accept_events),.event_ready(allocator_ready),
        .event_on(event_on),.event_source(event_source),.event_note(event_note),
        .event_velocity(event_velocity),.event_timbre(event_timbre),.cmd_valid(cmd_valid),.cmd_ready(1'b1),
        .cmd_on(cmd_on),.cmd_voice(cmd_voice),.cmd_note(cmd_note),.cmd_velocity(cmd_velocity),.cmd_timbre(cmd_timbre),
        .done_valid(1'b0),.done_ready(done_ready),.done_voice(2'd0),.active_count(active_count),
        .active_mask(active_mask),.held_mask(held_mask),.full_pulse(full_pulse),.ignored_pulse(),.done_error_pulse());
    wire [22:0] payload={event_on,event_source,event_note,event_velocity,event_timbre};
    reg stalled=0; reg [22:0] stalled_payload;
    reg [22:0] trace[0:63]; reg [31:0] trace_ms[0:63];
    reg [24:0] live_held=0; reg [6:0] live_note[0:24];
    integer delivered=0,engine_ons=0;
    reg [1:0] onset_voice[0:15]; reg full_seen=0;
    always @(posedge clk) begin
        if (!rst_n) begin stalled=0;live_held=0;delivered=0;engine_ons=0;full_seen=0;end
        else begin
            if(stalled && (!event_valid || payload!==stalled_payload))
                $fatal(1,"retrigger changed payload under backpressure");
            stalled=event_valid && !event_ready;stalled_payload=payload;
            if(full_pulse)full_seen=1;
            if(cmd_valid && cmd_on)begin onset_voice[engine_ons]=cmd_voice;engine_ons=engine_ons+1;end
            if(event_valid && event_ready)begin
                if(event_source>24)$fatal(1,"source escaped key namespace");
                if(event_on)begin
                    if(event_velocity==0)$fatal(1,"velocity-zero event remained NoteOn");
                    if(live_held[event_source] && live_note[event_source]!=event_note)
                        $fatal(1,"new pitch overwrote an unreleased key ownership");
                    live_note[event_source]=event_note;
                end else if(live_held[event_source] && live_note[event_source]!=event_note)
                    $fatal(1,"release addressed the remapped note instead of held note");
                live_held[event_source]=event_on;
                trace[delivered]=payload;trace_ms[delivered]=dut.time_ms;delivered=delivered+1;
            end
        end
    end
    function [79:0] score;
        input [15:0] index;input [31:0] delta;input [7:0] key,velocity,on;
        begin score={8'd0,on,velocity,key,delta,index};end
    endfunction
    task command;
        input [7:0] op;input [79:0] p;
        begin
            @(negedge clk);command_opcode=op;command_payload=p;command_valid=1;#1;
            if(!command_ready || command_status!=0)$fatal(1,"command rejected: %h %h status=%0d",op,p,command_status);
            @(negedge clk);command_valid=0;
        end
    endtask
    task reset_case;
        integer k;
        begin
            @(negedge clk);rst_n=0;command_valid=0;record_valid=0;accept_events=1;current_timbre=2;
            for(k=0;k<25;k=k+1)key_map_flat[k*7+:7]=60+k;
            repeat(3)@(negedge clk);rst_n=1;
        end
    endtask
    task wait_delivered;
        input integer target;integer timeout;
        begin timeout=0;while(delivered<target && timeout<1000)begin @(posedge clk);#1;timeout=timeout+1;end
            if(delivered!=target)$fatal(1,"event count %0d expected %0d",delivered,target);end
    endtask
    task wait_idle;
        integer timeout;
        begin timeout=0;while((!dut.idle || allocator.state!=0) && timeout<1000)begin @(posedge clk);#1;timeout=timeout+1;end
            if(!dut.idle || allocator.state!=0 || held_mask!=0 || live_held!=0)
                $fatal(1,"finished performance retained held voice: controller=%h allocator=%b",dut.held,held_mask);end
    endtask
    task expect_event;
        input integer index;input reg on;input [5:0] source;input [6:0] note,velocity;input [1:0] timbre;
        begin if(trace[index]!=={on,source,note,velocity,timbre})$fatal(1,"wrong event %0d: %h",index,trace[index]);end
    endtask
    task repeated_score;
        begin command(6,score(0,0,0,100,1));command(6,score(1,10,0,100,1));
            command(6,score(2,10,0,0,0));command(7,80'd3);command(4,80'd1);end
    endtask
    integer i,stop_action;reg [31:0] started_due_ms;
    initial begin
        reset_case();repeated_score();started_due_ms=dut.due_ms;wait_delivered(1);
        @(negedge clk);key_map_flat[6:0]=61;current_timbre=1;
        wait_delivered(4);wait_idle();
        expect_event(0,1,0,60,100,2);expect_event(1,0,0,60,0,2);
        expect_event(2,1,0,61,100,1);expect_event(3,0,0,61,0,1);
        // The initial zero-delay row may handshake on the next timer tick.
        // Subsequent rows must retain the scheduled epoch, not that handshake.
        if(trace_ms[1]-started_due_ms!=10 || trace_ms[3]-started_due_ms!=20)
            $fatal(1,"inserted release consumed or shifted the current score row: %0d,%0d,%0d,%0d",trace_ms[0],trace_ms[1],trace_ms[2],trace_ms[3]);

        reset_case();
        for(i=0;i<4;i=i+1)command(6,score(i,0,i,100,1));
        command(6,score(4,10,0,110,1));
        for(i=0;i<4;i=i+1)command(6,score(5+i,i==0 ? 10 : 0,i,0,0));
        command(7,80'd9);command(4,80'd1);wait_delivered(4);
        @(negedge clk);current_timbre=3;
        wait_delivered(9);wait_idle();
        if(full_seen || engine_ons!=5 || onset_voice[4]!=onset_voice[0] || active_count!=4)
            $fatal(1,"same-note retrigger failed with full voice allocation");
        expect_event(4,1,0,60,110,3);expect_event(5,0,0,60,0,3);

        reset_case();command(6,score(0,0,0,100,1));command(6,score(1,10,0,0,1));
        command(7,80'd2);command(4,80'd1);wait_delivered(1);
        @(negedge clk);key_map_flat[6:0]=61;current_timbre=1;
        wait_delivered(2);wait_idle();expect_event(1,0,0,60,0,2);
        if(engine_ons!=1 || guide_mask!=0)$fatal(1,"zero velocity generated an onset or lit the guide");
        reset_case();command(6,score(0,0,0,0,1));command(7,80'd1);command(4,80'd1);
        wait_delivered(1);wait_idle();expect_event(0,0,0,60,0,2);
        if(engine_ons!=0)$fatal(1,"orphan zero velocity created an audible voice");
        command(4,80'd6);repeat(10)@(negedge clk);
        if(guide_mask!=0 || guide_active)$fatal(1,"zero-velocity silent guide stayed lit");

        // Stop and Panic must drain a stalled pre-release without starting the
        // replacement pitch. The old note/timbre stay stable despite remapping.
        for(stop_action=0;stop_action<=5;stop_action=stop_action+5)begin
            reset_case();repeated_score();wait_delivered(1);
            @(negedge clk);accept_events=0;key_map_flat[6:0]=61;current_timbre=1;
            wait(event_valid);#1;
            if(event_on || event_note!=60 || event_timbre!=2 || !dut.event_release)
                $fatal(1,"replacement did not release original note first");
            @(negedge clk);key_map_flat[6:0]=62;current_timbre=3;
            command(4,stop_action);repeat(20)@(negedge clk);accept_events=1;
            wait_delivered(2);wait_idle();expect_event(1,0,0,60,0,2);
            if(engine_ons!=1 || score_position!=1)$fatal(1,"stop consumed or started replacement row");
        end

        // Record/replay uses the same retrigger ownership logic while retaining
        // the recorded note and timbre instead of the mutable live key map.
        reset_case();command(4,80'd2);
        @(negedge clk);record_valid=1;record_on=1;record_note=60;record_velocity=100;record_timbre=2;
        @(negedge clk);record_valid=0;repeat(10)@(negedge clk);
        record_valid=1;record_note=61;record_timbre=1;
        @(negedge clk);record_valid=0;repeat(10)@(negedge clk);
        record_valid=1;record_on=0;record_velocity=0;
        @(negedge clk);record_valid=0;command(4,80'd3);command(4,80'd8);
        wait_delivered(4);wait_idle();
        expect_event(0,1,0,60,100,2);expect_event(1,0,0,60,0,2);
        expect_event(2,1,0,61,100,1);expect_event(3,0,0,61,0,1);
        $display("PASS performance retrigger: remap/replay release ordering, same-note full allocation, timbre ownership, zero velocity, backpressure, Stop/Panic");
        $finish;
    end
    initial begin #1000000;$fatal(1,"performance retrigger watchdog");end
endmodule
