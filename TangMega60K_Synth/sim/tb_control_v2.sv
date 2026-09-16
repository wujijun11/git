`timescale 1ns/1ps

module source_allocator_case #(parameter N=64)(output reg finished=0);
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, event_valid=0, event_on=0, cmd_ready=0, done_valid=0;
    reg [5:0] event_source=0, done_voice=0;
    reg [6:0] event_note=0, event_velocity=0;
    reg [1:0] event_timbre=0;
    wire event_ready, cmd_valid, cmd_on, done_ready;
    wire [5:0] cmd_voice;
    wire [6:0] cmd_note, cmd_velocity, active_count;
    wire [1:0] cmd_timbre;
    wire [N-1:0] active_mask, held_mask;
    wire full_pulse, ignored_pulse, done_error_pulse;
    integer cycles, k, accepted=0, fulls=0, ignored=0, bad_done=0, previous_accepted;
    reg [22:0] held_command;
    voice_allocator_v2 #(.VOICE_COUNT(N), .ID_WIDTH(6)) dut(.*);
    always @(posedge clk) if(rst_n) begin
        if(cmd_valid && cmd_ready) accepted=accepted+1;
        if(full_pulse) fulls=fulls+1;
        if(ignored_pulse) ignored=ignored+1;
        if(done_error_pulse) bad_done=bad_done+1;
    end
    always @(negedge clk) if(rst_n) begin
        if(active_count !== $countones(active_mask)) $fatal(1,"V2 count/mask");
        if((held_mask & ~active_mask)!=0) $fatal(1,"V2 held must be active");
    end
    task send(input integer src, input bit on_value, input integer note_value, input integer vel);
        begin
            @(negedge clk);
            while(!event_ready) @(negedge clk);
            event_source=src; event_on=on_value; event_note=note_value;
            event_velocity=vel; event_timbre=2; event_valid=1;
            @(negedge clk); event_valid=0;
            // Payload may change immediately after acceptance. Source must be latched.
            event_source=63; event_note=127; event_velocity=0;
        end
    endtask
    task expect_cmd(input bit on_value, input integer id, input integer note_value, input integer vel);
        begin
            cycles=0;
            while(!cmd_valid) begin
                @(negedge clk); cycles=cycles+1;
                if(cycles>N+5) $fatal(1,"V2 command timeout");
            end
            held_command={on_value,6'(id),7'(note_value),7'(vel),2'd2};
            repeat(4) begin
                if(!cmd_valid || event_ready ||
                   {cmd_on,cmd_voice,cmd_note,cmd_velocity,cmd_timbre} !== held_command)
                    $fatal(1,"V2 source/command/backpressure N=%0d id=%0d expected=%0d",N,cmd_voice,id);
                @(negedge clk);
            end
            cmd_ready=1; @(negedge clk); cmd_ready=0;
            if(cmd_valid) $fatal(1,"V2 duplicated command");
        end
    endtask
    task idle;
        begin
            cycles=0;
            while(!event_ready) begin
                @(negedge clk); cycles=cycles+1;
                if(cycles>N+5) $fatal(1,"V2 idle timeout");
            end
            repeat(2) @(negedge clk);
        end
    endtask
    task done(input integer id);
        begin
            @(negedge clk);
            while(!done_ready) @(negedge clk);
            done_voice=id; done_valid=1;
            @(negedge clk); done_valid=0;
            repeat(2) @(negedge clk);
        end
    endtask
    task reset_dut;
        begin
            @(negedge clk); rst_n=0; event_valid=0; cmd_ready=0; done_valid=0;
            repeat(3) @(negedge clk);
            if(cmd_valid || event_ready || active_mask!=0 || held_mask!=0) $fatal(1,"V2 reset");
            rst_n=1;
        end
    endtask
    initial begin
        reset_dut();
        // Two chords overlap on C4; source 1 also owns E4.
        send(1,1,60,100); expect_cmd(1,0,60,100);
        send(2,1,60,90); expect_cmd(1,1,60,90);
        send(1,1,64,80); expect_cmd(1,2,64,80);
        if(active_count!=3) $fatal(1,"V2 merged sources or chord notes");
        send(1,1,60,70); expect_cmd(1,0,60,70);
        if(active_count!=3) $fatal(1,"V2 same-owner retrigger must reuse");
        send(3,0,60,0); idle();
        if(ignored!=1 || held_mask[1:0]!=2'b11) $fatal(1,"V2 wrong owner released a note");
        send(1,0,60,0); expect_cmd(0,0,60,0);
        if(held_mask[0] || !held_mask[1] || !held_mask[2] || active_count!=3)
            $fatal(1,"V2 overlapping chord note-off");
        send(1,1,60,110); expect_cmd(1,3,60,110);
        if(active_count!=4) $fatal(1,"V2 release tail overwritten");
        done(0); done(0); done(1);
        if(active_count!=3 || bad_done!=2) $fatal(1,"V2 invalid done guard");
        send(1,0,64,0); expect_cmd(0,2,64,0); done(2);
        if(!held_mask[1] || !held_mask[3]) $fatal(1,"V2 chord released unrelated note");
        reset_dut();
        for(k=0;k<N;k=k+1) begin
            send(k,1,60,100); expect_cmd(1,k,60,100);
        end
        if(active_count!=N || active_mask!={N{1'b1}}) $fatal(1,"V2 capacity same pitch many sources");
        previous_accepted=accepted;
        send(63,1,61,100); idle();
        if(fulls!=1 || accepted!=previous_accepted) $fatal(1,"V2 full rejection");
        send(0,1,60,50); expect_cmd(1,0,60,50); // allowed even at full capacity
        send(N-1,1,60,0); expect_cmd(0,N-1,60,0); // velocity zero releases THIS owner
        if(held_mask[N-1] || !held_mask[0]) $fatal(1,"V2 zero velocity owner");
        send(63,1,61,100); idle();
        if(fulls!=2 || active_count!=N) $fatal(1,"V2 full tails");
        // Done must be drained before the waiting event is accepted.
        @(negedge clk);
        done_voice=N-1; done_valid=1;
        event_source=63; event_note=61; event_velocity=100; event_on=1; event_valid=1;
        #1; if(event_ready) $fatal(1,"V2 completion priority");
        @(negedge clk); done_valid=0;
        @(negedge clk); event_valid=0;
        expect_cmd(1,N-1,61,100);
        send(0,0,60,0);
        while(!cmd_valid) @(negedge clk);
        reset_dut();
        send(63,1,69,100); expect_cmd(1,0,69,100);
        $display("V2 SOURCE CASE PASSED N=%0d",N);
        finished=1;
    end
endmodule

module expression_case(output reg finished=0);
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, expr_valid=0, engine_sample_begin=0;
    reg [11:0] expr_gain=2048;
    reg signed [12:0] expr_bend_cents=0;
    reg [7:0] expr_vibrato_cents=0;
    wire expr_ready, expr_applied;
    wire [11:0] active_gain;
    wire signed [12:0] active_bend_cents;
    wire [7:0] active_vibrato_cents;
    reg event_valid=0, cmd_ready=0;
    wire event_ready, cmd_valid;
    wire [6:0] active_count;
    wire [63:0] held_mask;
    integer accepted_commands=0;
    captain_control_top_v2 dut (
        .clk(clk), .rst_n(rst_n),
        .event_valid(event_valid), .event_ready(event_ready),
        .event_on(1'b1), .event_source(6'd3), .event_note(7'd60),
        .event_velocity(7'd100), .event_timbre(2'd0),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .done_valid(1'b0), .done_voice(6'd0),
        .active_count(active_count), .held_mask(held_mask),
        .expr_valid(expr_valid), .expr_ready(expr_ready), .expr_gain(expr_gain),
        .expr_bend_cents(expr_bend_cents), .expr_vibrato_cents(expr_vibrato_cents),
        .engine_sample_begin(engine_sample_begin), .active_gain(active_gain),
        .active_bend_cents(active_bend_cents), .active_vibrato_cents(active_vibrato_cents),
        .expr_applied(expr_applied)
    );
    always @(posedge clk) if(rst_n && cmd_valid && cmd_ready) accepted_commands=accepted_commands+1;
    task check(input integer gain, input integer bend, input integer vibrato, input bit pulse);
        begin
            if(active_gain!==12'(gain) || active_bend_cents!==13'(bend) ||
               active_vibrato_cents!==8'(vibrato) || expr_applied!==pulse)
                $fatal(1,"expression snapshot g=%0d b=%0d v=%0d pulse=%0d",active_gain,active_bend_cents,active_vibrato_cents,expr_applied);
        end
    endtask
    task payload(input integer gain,input integer bend,input integer vibrato);
        begin expr_gain=gain; expr_bend_cents=bend; expr_vibrato_cents=vibrato; end
    endtask
    initial begin
        repeat(3) @(negedge clk);
        check(2048,0,0,0);
        if(expr_ready) $fatal(1,"expression ready during reset");
        rst_n=1;
        // Queue A while launching a note. No active parameters change mid-sample.
        @(negedge clk); event_valid=1; expr_valid=1; payload(1024,-1200,30);
        @(negedge clk); event_valid=0; expr_valid=0;
        check(2048,0,0,0);
        if(expr_ready) $fatal(1,"mailbox must backpressure");
        // B waits until A is applied; note path proceeds independently meanwhile.
        expr_valid=1; payload(4095,3000,255);
        repeat(70) begin @(negedge clk); check(2048,0,0,0); end
        if(!cmd_valid || active_count!=0 || expr_ready) $fatal(1,"expression blocked note path / no backpressure");
        engine_sample_begin=1;
        #1; if(!expr_ready) $fatal(1,"consume/refill should be ready");
        @(negedge clk); engine_sample_begin=0; expr_valid=0;
        check(1024,-1200,30,1); // old A first; B queued, not lost
        cmd_ready=1;
        @(negedge clk); check(1024,-1200,30,0);
        if(accepted_commands!=1 || active_count!=1) $fatal(1,"note handshake");
        engine_sample_begin=1;
        @(negedge clk); engine_sample_begin=0;
        check(4095,2400,100,1); // bounded bend and vibrato
        @(negedge clk); check(4095,2400,100,0);
        // Independent changes: pressure only, bend only, vibrato only.
        expr_valid=1; payload(0,2400,100); engine_sample_begin=1;
        @(negedge clk); expr_valid=0; engine_sample_begin=0;
        check(0,2400,100,1);
        @(negedge clk); expr_valid=1; payload(0,-4096,100); engine_sample_begin=1;
        @(negedge clk); expr_valid=0; engine_sample_begin=0;
        check(0,-2400,100,1);
        @(negedge clk); expr_valid=1; payload(0,-2400,0); engine_sample_begin=1;
        @(negedge clk); expr_valid=0; engine_sample_begin=0;
        check(0,-2400,0,1);
        // No update: keep active bundle even at the next sample boundary.
        @(negedge clk); engine_sample_begin=1;
        @(negedge clk); engine_sample_begin=0; check(0,-2400,0,0);
        if(accepted_commands!=1 || active_count!=1 || held_mask!=64'd1)
            $fatal(1,"expression retriggered/released note");
        // Reset discards pending changes and restores unity/neutral parameters.
        expr_valid=1; payload(1,333,99);
        @(negedge clk); expr_valid=0; rst_n=0;
        @(negedge clk); check(2048,0,0,0);
        if(expr_ready || cmd_valid || active_count!=0) $fatal(1,"reset pending expression/note");
        rst_n=1; engine_sample_begin=1;
        @(negedge clk); engine_sample_begin=0; check(2048,0,0,0);
        $display("V2 EXPRESSION CASE PASSED: defaults/coherence/backpressure/clamp/independence/reset");
        finished=1;
    end
endmodule

module tb_control_v2;
    wire done4,done64,done_expr;
    source_allocator_case #(.N(4)) a4(done4);
    source_allocator_case #(.N(64)) a64(done64);
    expression_case expression_test(done_expr);
    initial begin
        wait(done4 && done64 && done_expr);
        $display("ALL V2 CONTROL TESTS PASSED");
        $finish;
    end
    initial begin #2000000; $fatal(1,"V2 watchdog"); end
endmodule
