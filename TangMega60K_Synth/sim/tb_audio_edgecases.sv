`timescale 1ns/1ps
module tb_audio_edgecases;
    reg test_passed=0;
    reg clk=0,rst_n=0;
    always #(1.0e9/49152000.0/2.0) clk=~clk;
    reg diag_mode=1,start=0,stop=0;
    wire diag_valid,diag_ready,diag_on,busy,holding,released,diag_error,start_ready;
    wire [5:0] diag_source;
    wire [6:0] diag_note,diag_velocity;
    wire [1:0] diag_timbre;
    reg manual_valid=0,manual_on=0;
    reg [5:0] manual_source=0;
    reg [6:0] manual_note=69;
    wire event_valid=diag_mode ? diag_valid : manual_valid;
    wire event_on=diag_mode ? diag_on : manual_on;
    wire [5:0] event_source=diag_mode ? diag_source : manual_source;
    wire [6:0] event_note=diag_mode ? diag_note : manual_note;
    wire event_ready;
    assign diag_ready=diag_mode && event_ready;
    wire [6:0] active_count;
    wire [63:0] active_mask,held_mask;
    wire full_pulse,ignored_pulse,done_error;
    live64_event_source producer(.clk(clk),.rst_n(rst_n),.start(start),.stop(stop),
        .active_count(active_count),.allocation_error(full_pulse || done_error),
        .start_ready(start_ready),.busy(busy),.holding(holding),.released_pulse(released),.error(diag_error),
        .event_valid(diag_valid),.event_ready(diag_ready),.event_on(diag_on),.event_source(diag_source),
        .event_note(diag_note),.event_velocity(diag_velocity),.event_timbre(diag_timbre));
    wire cv,cr,co,dv,dr,engine_cr,alloc_dr;
    wire [5:0] voice,dvoice;
    wire [6:0] note,velocity;
    wire [1:0] timbre;
    reg permit_cmd=1,permit_done=1,block_sample=0;
    assign cr=engine_cr && permit_cmd;
    assign dr=alloc_dr && permit_done;
    wire begin_frame,expr_ready,expr_applied;
    reg expr_valid=0;
    reg [11:0] gain=2048;
    reg signed [12:0] bend=0;
    reg [7:0] depth=0;
    wire [11:0] active_gain;
    wire signed [12:0] active_bend;
    wire [7:0] active_depth;
    captain_control_top_v2 captain(.clk(clk),.rst_n(rst_n),
        .event_valid(event_valid),.event_ready(event_ready),.event_on(event_on),
        .event_source(event_source),.event_note(event_note),.event_velocity(7'd100),.event_timbre(2'd0),
        .expr_valid(expr_valid),.expr_ready(expr_ready),.expr_gain(gain),.expr_bend_cents(bend),
        .expr_vibrato_cents(depth),.engine_sample_begin(begin_frame),.active_gain(active_gain),
        .active_bend_cents(active_bend),.active_vibrato_cents(active_depth),.expr_applied(expr_applied),
        .cmd_valid(cv),.cmd_ready(cr),.cmd_on(co),.cmd_voice(voice),.cmd_note(note),
        .cmd_velocity(velocity),.cmd_timbre(timbre),.done_valid(dv && permit_done),
        .done_ready(alloc_dr),.done_voice(dvoice),.active_count(active_count),.active_mask(active_mask),
        .held_mask(held_mask),.full_pulse(full_pulse),.ignored_pulse(ignored_pulse),.done_error_pulse(done_error));
    wire sv;
    wire signed [23:0] sl,sr;
    reg [31:0] rng=32'h12345678;
    wire sample_ready=!block_sample && rng[2:0]!=0;
    voice_engine dut(.clk(clk),.rst_n(rst_n),.cmd_valid(cv && permit_cmd),.cmd_ready(engine_cr),
        .cmd_on(co),.cmd_voice(voice),.cmd_note(note),.cmd_velocity(velocity),.cmd_timbre(timbre),
        .done_valid(dv),.done_ready(dr),.done_voice(dvoice),.sample_valid(sv),.sample_ready(sample_ready),
        .sample_left(sl),.sample_right(sr),.engine_sample_begin(begin_frame),.active_gain(active_gain),
        .active_bend_cents(active_bend),.active_vibrato_cents(active_depth));
    integer outputs=0,done_count=0,on_count=0,off_count=0,max_active=0,retriggers=0;
    reg previous_sample_stall=0,previous_done_stall=0,previous_cmd_stall=0;
    reg [47:0] old_sample;
    reg [5:0] old_done;
    reg [22:0] old_cmd;
    always @(posedge clk) begin
        rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        if(!rst_n) begin
            outputs=0; done_count=0; on_count=0; off_count=0; max_active=0;
            previous_sample_stall=0; previous_done_stall=0; previous_cmd_stall=0;
        end else begin
            if(full_pulse || ignored_pulse || done_error || diag_error) $fatal(1,"unexpected control error");
            if(previous_sample_stall && (!sv || {sl,sr}!==old_sample)) $fatal(1,"sample stall");
            if(previous_done_stall && (!dv || dvoice!==old_done)) $fatal(1,"done stall");
            if(previous_cmd_stall && (!cv || {co,voice,note,velocity,timbre}!==old_cmd)) $fatal(1,"command stall");
            previous_sample_stall=sv && !sample_ready; old_sample={sl,sr};
            previous_done_stall=dv && !dr; old_done=dvoice;
            previous_cmd_stall=cv && !cr; old_cmd={co,voice,note,velocity,timbre};
            if(sv && sample_ready) begin
                if((^{sl,sr})===1'bx) $fatal(1,"unknown PCM");
                outputs=outputs+1;
            end
            if(dv && dr) done_count=done_count+1;
            if(cv && cr) begin if(co) on_count=on_count+1; else off_count=off_count+1; end
            if(active_count>max_active) max_active=active_count;
        end
    end
    reg [31:0] preserved_phase;
    reg [23:0] preserved_env;
    reg [5:0] preserved_id;
    always @(posedge clk) if(rst_n && dut.state==3 && dut.pending_on && dut.r_active) begin
        preserved_phase=dut.r_phase; preserved_env=dut.r_env; preserved_id=dut.pending_voice;
        #0.001;
        if(dut.u_state.mem[preserved_id][31:0]!==preserved_phase ||
           dut.u_state.mem[preserved_id][87:64]!==preserved_env) $fatal(1,"held retrigger discontinuity");
        retriggers=retriggers+1;
    end
    task frames(input integer n);
        integer target; begin target=outputs+n; wait(outputs>=target); @(negedge clk); end
    endtask
    task send_note(input bit turn_on,input integer src,input integer midi);
        begin
            @(negedge clk); manual_valid=1; manual_on=turn_on; manual_source=src; manual_note=midi;
            do @(posedge clk); while(!event_ready);
            @(negedge clk); manual_valid=0;
        end
    endtask
    task send_expr(input integer g,input integer b,input integer d);
        begin
            @(negedge clk); expr_valid=1; gain=g; bend=b; depth=d;
            do @(posedge clk); while(!expr_ready);
            @(negedge clk); expr_valid=0;
        end
    endtask
    task launch;
        begin wait(start_ready); @(negedge clk); start=1; @(negedge clk); start=0; end
    endtask
    integer j,early_start,done_before;
    reg [31:0] frozen_lfo;
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        // Stop while the real allocator has an unaccepted engine command.
        permit_cmd=0; launch(); wait(cv); @(negedge clk); stop=1;
        repeat(500) @(negedge clk); stop=0; permit_cmd=1;
        wait(released); frames(5);
        if(on_count!=2 || off_count!=2 || done_count!=2 || active_count!=0)
            $fatal(1,"startup-stop real allocator sequence");
        launch(); wait(holding); frames(500);
        @(negedge clk); stop=1; start=1; @(negedge clk); stop=0;
        wait(released); frames(5);
        if(busy || active_count!=0 || done_count!=66) $fatal(1,"full selftest reclaim/restart");
        @(negedge clk); start=0; diag_mode=0;
        // One attack sample, then release: must end well before full release time.
        done_before=done_count; send_note(1,1,69); frames(2); send_note(0,1,69); early_start=outputs;
        wait(done_count==done_before+1);
        if(outputs-early_start>80) $fatal(1,"early release took too long");
        frames(3); if(active_count!=0) $fatal(1,"early release leak");
        // Re-trigger while held: keep same slot, phase and current envelope.
        send_note(1,1,60); frames(5); done_before=done_count;
        for(j=0;j<32;j=j+1) send_note(1,1,60);
        frames(5);
        if(active_count!=1 || done_count!=done_before || retriggers<32) $fatal(1,"held retrigger ownership");
        // Fast on/off under completion backpressure must preserve every tail.
        permit_done=0;
        for(j=0;j<32;j=j+1) begin send_note(1,2,69); send_note(0,2,69); end
        frames(2000);
        if(active_count!=33 || $countones(held_mask)!=1 || $countones(dut.done_pending)!=32)
            $fatal(1,"rapid release lost tails active=%0d",active_count);
        // Queue expressions while sample output is blocked, then release it.
        block_sample=1; wait(sv); @(negedge clk); frozen_lfo=dut.u_expression.lfo_phase;
        send_expr(1024,-300,20); repeat(1500) @(negedge clk);
        if(dut.u_expression.lfo_phase!==frozen_lfo) $fatal(1,"LFO advanced under stall");
        block_sample=0;
        for(j=0;j<24;j=j+1) send_expr(2048+j*8,j*8,j);
        send_expr(3072,300,40); frames(500);
        if(dut.u_expression.gain_smooth!=3072 || dut.u_expression.bend_smooth!=300 ||
           dut.u_expression.depth_smooth!=40 || active_count!=33) $fatal(1,"expression update lost/retriggered");
        permit_done=1; wait(active_count==1); frames(3);
        if(done_count-done_before!=32 || $countones(held_mask)!=1) $fatal(1,"rapid tails done count");
        send_note(0,1,60); wait(active_count==0); frames(5);
        if(sl!==0 || sr!==0) $fatal(1,"final silence");
        // Coordinated reset during stalled PCM clears both ownership and output.
        send_note(1,3,72); frames(10); block_sample=1; wait(sv);
        @(negedge clk); rst_n=0; repeat(4) @(negedge clk);
        rst_n=1; block_sample=0; frames(5);
        if(active_count!=0 || dv || sl!==0 || sr!==0) $fatal(1,"reset leakage");
        $display("AUDIO EDGECASES PASSED held_retriggers=%0d rapid_tails=32 expression_packets=26 start_stop_cmd_stall=covered reset=covered",retriggers);
        test_passed=1; $finish;
    end
    initial begin #(1.0e9); $fatal(1,"edgecase timeout"); end
endmodule
