`timescale 1ns/1ps
module tb_audio_engine;
    reg test_passed=0;
    parameter N=4;
    reg clk=0,rst_n=0;
    always #10 clk=~clk; // Logic test; audio time is accepted sample index / 48000.
    reg event_valid=0,event_on=0;
    reg [5:0] event_source=0;
    reg [6:0] event_note=69,event_velocity=127;
    reg [1:0] event_timbre=0;
    wire event_ready,cmd_valid,cmd_ready,cmd_on;
    wire [5:0] cmd_voice,done_voice;
    wire [6:0] cmd_note,cmd_velocity,active_count;
    wire [1:0] cmd_timbre;
    wire [N-1:0] active_mask,held_mask;
    wire done_valid,allocator_done_ready,done_ready;
    reg permit_done=1;
    assign done_ready=allocator_done_ready && permit_done;
    wire full_pulse,ignored_pulse,done_error;
    voice_allocator_v2 #(.VOICE_COUNT(N),.ID_WIDTH(6)) allocator (
        .clk(clk),.rst_n(rst_n),.event_valid(event_valid),.event_ready(event_ready),
        .event_on(event_on),.event_source(event_source),.event_note(event_note),
        .event_velocity(event_velocity),.event_timbre(event_timbre),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_on(cmd_on),.cmd_voice(cmd_voice),
        .cmd_note(cmd_note),.cmd_velocity(cmd_velocity),.cmd_timbre(cmd_timbre),
        .done_valid(done_valid && permit_done),.done_ready(allocator_done_ready),.done_voice(done_voice),
        .active_count(active_count),.active_mask(active_mask),.held_mask(held_mask),
        .full_pulse(full_pulse),.ignored_pulse(ignored_pulse),.done_error_pulse(done_error)
    );
    reg expr_valid=0;
    wire expr_ready,expr_applied;
    reg [11:0] expr_gain=2048;
    reg signed [12:0] expr_bend=0;
    reg [7:0] expr_depth=0;
    wire begin_frame;
    wire [11:0] active_gain;
    wire signed [12:0] active_bend;
    wire [7:0] active_depth;
    expression_controls_v2 expression (
        .clk(clk),.rst_n(rst_n),.expr_valid(expr_valid),.expr_ready(expr_ready),
        .expr_gain(expr_gain),.expr_bend_cents(expr_bend),.expr_vibrato_cents(expr_depth),
        .engine_sample_begin(begin_frame),.active_gain(active_gain),
        .active_bend_cents(active_bend),.active_vibrato_cents(active_depth),.expr_applied(expr_applied)
    );
    reg sample_ready=1;
    wire sample_valid;
    wire signed [23:0] sl,sr;
    voice_engine #(.VOICE_COUNT(N)) dut (
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_on(cmd_on),
        .cmd_voice(cmd_voice),.cmd_note(cmd_note),.cmd_velocity(cmd_velocity),.cmd_timbre(cmd_timbre),
        .done_valid(done_valid),.done_ready(done_ready),.done_voice(done_voice),
        .sample_valid(sample_valid),.sample_ready(sample_ready),.sample_left(sl),.sample_right(sr),
        .engine_sample_begin(begin_frame),.active_gain(active_gain),
        .active_bend_cents(active_bend),.active_vibrato_cents(active_depth)
    );
    wire ref_ready,ref_valid,ref_done,ref_begin;
    wire [5:0] ref_done_voice;
    wire signed [23:0] ref_l,ref_r;
    // Explicit no-expression reference path: same core, compile-time neutral.
    // External PCM frequency/RMS and memory independence tests are additional,
    // so equivalence alone is not being used as proof of audio correctness.
    voice_engine #(.VOICE_COUNT(N),.EXPRESSION_ENABLE(0)) reference_engine (
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(ref_ready),.cmd_on(cmd_on),
        .cmd_voice(cmd_voice),.cmd_note(cmd_note),.cmd_velocity(cmd_velocity),.cmd_timbre(cmd_timbre),
        .done_valid(ref_done),.done_ready(done_ready),.done_voice(ref_done_voice),
        .sample_valid(ref_valid),.sample_ready(sample_ready),.sample_left(ref_l),.sample_right(ref_r),
        .engine_sample_begin(ref_begin),.active_gain(12'd2048),
        .active_bend_cents(13'sd0),.active_vibrato_cents(8'd0)
    );
    integer cycle=0,begins=0,outputs=0,dones=0,max_latency=0,start_cycle=0;
    integer fulls=0,latency;
    reg check_neutral=1;
    reg previous_stall=0,previous_done_stall=0;
    reg [47:0] held_sample;
    reg [5:0] held_done;
    reg [31:0] previous_lfo;
    reg previous_latch=0;
    integer expected_gain=2048,expected_bend=0,expected_depth=0;
    integer bounded_bend,bounded_depth;
    reg [22:0] saved_ratio;
    reg [11:0] saved_gain;
    reg [31:0] frame_seen=0;
    reg [63:0] visited=0;
    reg [31:0] phases[0:N-1];
    integer j;
    initial for(j=0;j<N;j=j+1) phases[j]=0;
    always @(posedge clk) begin
        cycle=cycle+1;
        if(!rst_n) begin
            previous_stall=0; previous_done_stall=0;
            previous_latch=0; previous_lfo=0; visited=0;
            expected_gain=2048; expected_bend=0; expected_depth=0;
            for(j=0;j<N;j=j+1) phases[j]=0;
        end else begin
            if(done_error) $fatal(1,"N=%0d illegal/duplicate done",N);
            if(full_pulse) fulls=fulls+1;
            if(cmd_ready!==ref_ready || sample_valid!==ref_valid) $fatal(1,"reference scheduling mismatch");
            if(previous_stall && (!sample_valid || {sl,sr}!==held_sample)) $fatal(1,"sample backpressure corruption");
            if(previous_done_stall && (!done_valid || done_voice!==held_done)) $fatal(1,"done backpressure corruption");
            previous_stall=sample_valid && !sample_ready; held_sample={sl,sr};
            previous_done_stall=done_valid && !done_ready; held_done=done_voice;
            if(done_valid && done_ready) dones=dones+1;
            if(begin_frame) begin begins=begins+1; start_cycle=cycle; visited=0; end
            // Once per generated frame, never once per voice or while output stalls.
            if(previous_latch) begin
                if(dut.u_expression.lfo_phase!==previous_lfo+32'd447392) $fatal(1,"LFO step");
                if(dut.frame_gain!=expected_gain || $signed(dut.u_expression.bend_smooth)!=expected_bend ||
                    dut.u_expression.depth_smooth!=expected_depth) $fatal(1,"sample snapshot latency or smoothing error");
            end else if(dut.u_expression.lfo_phase!==previous_lfo) $fatal(1,"LFO advanced without frame");
            previous_lfo=dut.u_expression.lfo_phase;
            previous_latch=(dut.state==dut.LATCH);
            if(previous_latch) begin
                bounded_bend=$signed(active_bend);
                if(bounded_bend>2400) bounded_bend=2400;
                if(bounded_bend < -2400) bounded_bend=-2400;
                bounded_depth=(active_depth>100) ? 100:active_depth;
                if(active_gain>expected_gain) expected_gain=(active_gain-expected_gain>8) ? expected_gain+8:active_gain;
                else expected_gain=(expected_gain-active_gain>8) ? expected_gain-8:active_gain;
                if(bounded_bend>expected_bend) expected_bend=(bounded_bend-expected_bend>4) ? expected_bend+4:bounded_bend;
                else expected_bend=(expected_bend-bounded_bend>4) ? expected_bend-4:bounded_bend;
                if(bounded_depth>expected_depth) expected_depth=expected_depth+1;
                else if(bounded_depth<expected_depth) expected_depth=expected_depth-1;
            end
            if(dut.state==dut.V_READ && dut.voice_id==0) begin
                saved_ratio=dut.frame_ratio; saved_gain=dut.frame_gain;
            end
            if(dut.state>=dut.V_READ && dut.state<=dut.V_WRITE) begin
                if(dut.frame_ratio!==saved_ratio || dut.frame_gain!==saved_gain) $fatal(1,"torn expression snapshot");
            end
            if(dut.state==dut.CMD_WRITE && dut.pending_on && !dut.r_active)
                phases[dut.pending_voice]=0;
            if(dut.state==dut.V_CALC) begin
                if(dut.r_phase!==phases[dut.voice_id]) $fatal(1,"voice state interference id=%0d",dut.voice_id);
            end
            if(dut.state==dut.V_WRITE) begin
                if(visited[dut.voice_id]) $fatal(1,"voice processed twice per frame");
                visited[dut.voice_id]=1;
                phases[dut.voice_id]=dut.w_active ? phases[dut.voice_id]+dut.effective_ftw : phases[dut.voice_id];
                if(dut.phase_next!==phases[dut.voice_id]) $fatal(1,"phase writeback mismatch");
            end
            if(dut.state==dut.FX_SEND) begin
                if($countones(visited)!=N) $fatal(1,"missing voice in frame");
                latency=cycle-start_cycle;
                if(latency>max_latency) max_latency=latency;
                if(latency>=1024) $fatal(1,"missed 48k frame budget %0d",latency);
            end
            if(sample_valid && sample_ready) begin
                outputs=outputs+1;
                if((^sl)===1'bx || (^sr)===1'bx) $fatal(1,"unknown PCM");
                if(check_neutral && {sl,sr}!=={ref_l,ref_r}) $fatal(1,"neutral not bit exact");
            end
        end
    end
    task send_event(input bit on_value,input integer source,note,velocity,timbre);
        begin
            @(negedge clk); event_valid=1; event_on=on_value; event_source=source;
            event_note=note; event_velocity=velocity; event_timbre=timbre;
            do @(posedge clk); while(!event_ready);
            @(negedge clk); event_valid=0;
            // Wait until the allocator has issued and the engine has applied it.
            wait(cmd_valid); do @(posedge clk); while(!cmd_ready);
            @(negedge clk); wait(!dut.pending_command); @(negedge clk);
        end
    endtask
    task expression_set(input integer g,b,d);
        begin
            @(negedge clk); expr_gain=g; expr_bend=b; expr_depth=d; expr_valid=1;
            do @(posedge clk); while(!expr_ready);
            @(negedge clk); expr_valid=0;
        end
    endtask
    task frames(input integer count);
        integer k;
        begin for(k=0;k<count;k=k+1) begin
            do @(posedge clk); while(!(sample_valid && sample_ready));
            @(negedge clk);
        end end
    endtask
    integer csv,segment=0;
    real rms,frequency,rms_neutral,frequency_neutral;
    real power_sum,x,prev,first_cross,last_cross,cross_at;
    integer crosses,k;
    task measure(input integer count,input integer tag);
        begin
            power_sum=0; prev=0; crosses=0; first_cross=0; last_cross=0;
            for(k=0;k<count;k=k+1) begin
                do @(posedge clk); while(!(sample_valid && sample_ready));
                x=$signed(sl); power_sum=power_sum+x*x;
                if(k>0 && prev<0 && x>=0) begin
                    cross_at=(k-1)+(-prev)/(x-prev);
                    if(crosses==0) first_cross=cross_at;
                    last_cross=cross_at; crosses=crosses+1;
                end
                prev=x;
                $fdisplay(csv,"%0d,%0d,%0d,%0d",tag,k,$signed(sl),$signed(sr));
                @(negedge clk);
            end
            rms=$sqrt(power_sum/count);
            frequency=(crosses>1) ? (crosses-1)*48000.0/(last_cross-first_cross) : 0;
            $display("MEASURE N=%0d tag=%0d samples=%0d rms=%0.5f f=%0.6f",N,tag,count,rms,frequency);
        end
    endtask
    integer before_done,before_full,before_begin;
    reg [31:0] stalled_phase;
    reg [5:0] stalled_done;
    real lo_ftw,hi_ftw,expected;
    initial begin
        csv=$fopen($sformatf("sim/audio_results/pcm_%0d.csv",N),"w");
        if(!csv) $fatal(1,"cannot open samples");
        $fdisplay(csv,"segment,index,left,right");
        repeat(5) @(negedge clk); rst_n=1;
        frames(3); if(sl!==0 || sr!==0) $fatal(1,"startup silence");
        // Nonempty neutral snapshot must also remain bit exact.
        expression_set(2048,0,0);
        send_event(1,0,69,127,0);
        frames(5000);
        measure(4800,0); rms_neutral=rms; frequency_neutral=frequency;
        if(frequency<439.9 || frequency>440.1 || rms<10000) $fatal(1,"DDS frequency/amplitude");
        $display("NEUTRAL BIT EXACT N=%0d frames=%0d",N,outputs);
        check_neutral=0;
        expression_set(1024,0,0); frames(300); measure(4800,1);
        if(rms/rms_neutral<0.499 || rms/rms_neutral>0.501) $fatal(1,"gain not half");
        if(frequency<439.9 || frequency>440.1) $fatal(1,"gain changed pitch");
        expression_set(2048,1200,0); frames(400); measure(4800,2);
        if(frequency<879.8 || frequency>880.2) $fatal(1,"positive octave bend");
        expression_set(2048,-1200,0); frames(700); measure(4800,3);
        if(frequency<219.9 || frequency>220.1) $fatal(1,"negative octave bend");
        // Gain=0 is mute, not note-off or done.
        before_done=dones;
        expression_set(0,0,0); frames(700);
        repeat(20) begin frames(1); if(sl!==0 || sr!==0) $fatal(1,"mute failed"); end
        if(active_count!=1 || dones!=before_done) $fatal(1,"mute freed held voice");
        expression_set(2048,0,100); frames(700);
        lo_ftw=1.0e20; hi_ftw=0;
        fork
            begin
                repeat(21000) begin
                    wait(dut.state==dut.V_ADDR && dut.voice_id==0); #1;
                    if(dut.effective_ftw<lo_ftw) lo_ftw=dut.effective_ftw;
                    if(dut.effective_ftw>hi_ftw) hi_ftw=dut.effective_ftw;
                    @(negedge clk); wait(dut.state!=dut.V_ADDR);
                end
            end
            begin measure(21002,4); end
        join
        expected=39370534.0*(2.0**(100.0/1200.0));
        if(hi_ftw<expected-100 || hi_ftw>expected+100) $fatal(1,"vibrato positive peak %f",hi_ftw);
        expected=39370534.0*(2.0**(-100.0/1200.0));
        if(lo_ftw<expected-100 || lo_ftw>expected+100) $fatal(1,"vibrato negative peak %f",lo_ftw);
        $display("VIBRATO N=%0d minFTW=%0.0f maxFTW=%0.0f 5Hz step checked every frame",N,lo_ftw,hi_ftw);
        expression_set(2048,0,0); frames(300);
        // Held retrigger uses same voice, preserves envelope/phase, no done.
        send_event(1,0,69,127,1);
        if(active_count!=1) $fatal(1,"retrigger allocated another voice");
        frames(5000); measure(4800,5);
        if(frequency<439.9 || frequency>440.1) $fatal(1,"timbre changed fundamental");
        // Same note from another source, release tail, then press again.
        send_event(1,1,69,100,0); frames(500);
        send_event(0,1,69,0,3);
        send_event(1,1,69,100,0);
        if(active_count!=3 || !held_mask[0]) $fatal(1,"tail retrigger/source independence");
        frames(5000); if(active_count!=2) $fatal(1,"old tail not reclaimed");
        send_event(0,1,69,0,3); frames(5000);
        if(active_count!=1 || !held_mask[0]) $fatal(1,"independent release affected other source");
        // Two same-note sources must remain independent; fill every slot.
        for(j=1;j<N;j=j+1) send_event(1,j,69,127,j%2);
        frames(5000);
        if(active_count!=N) $fatal(1,"full polyphony missing");
        before_full=fulls;
        @(negedge clk); event_valid=1; event_on=1; event_source=63; event_note=120;
        do @(posedge clk); while(!event_ready);
        @(negedge clk); event_valid=0;
        wait(fulls==before_full+1);
        if(active_count!=N) $fatal(1,"full rejection changed ownership");
        measure(1024,6);
        // Force output backpressure while new expression packet is queued.
        @(negedge clk); sample_ready=0; wait(sample_valid); @(negedge clk);
        stalled_phase=dut.u_expression.lfo_phase; before_begin=begins;
        expression_set(4095,2400,100);
        repeat(2000) @(negedge clk);
        if(dut.u_expression.lfo_phase!==stalled_phase || begins!=before_begin) $fatal(1,"advanced while stalled");
        if(active_gain!=2048 || active_bend!=0 || active_depth!=0) $fatal(1,"committed without begin");
        sample_ready=1; frames(800);
        if(active_gain!=4095 || active_bend!=2400 || active_depth!=100) $fatal(1,"snapshot did not commit");
        // All release completions must queue despite done backpressure.
        @(negedge clk); permit_done=0; before_done=dones;
        for(j=0;j<N;j=j+1) send_event(0,j,69,0,3);
        frames(5000);
        if(!done_valid || active_count!=N || held_mask!=0) $fatal(1,"release ownership/queue");
        if($countones(dut.done_pending)!=N) $fatal(1,"lost simultaneous completions");
        repeat(100) @(negedge clk);
        permit_done=1;
        wait(active_count==0); frames(5);
        if(dones-before_done!=N) $fatal(1,"done count mismatch");
        if(sl!==0 || sr!==0) $fatal(1,"tail not silent");
        // Reuse highest ID before any stale notification can escape.
        expression_set(2048,0,0); frames(700);
        for(j=0;j<N;j=j+1) send_event(1,j,69+j%12,100,0);
        frames(10); if(active_count!=N || done_valid) $fatal(1,"reuse/stale done");
        // Reset while output is held must invalidate all states and messages.
        @(negedge clk); sample_ready=0; wait(sample_valid); @(negedge clk); rst_n=0;
        repeat(3) @(negedge clk); rst_n=1; sample_ready=1;
        frames(5);
        if(active_count!=0 || done_valid || sl!==0 || sr!==0) $fatal(1,"reset stale state");
        $fclose(csv);
        $display("AUDIO ENGINE PASSED N=%0d max_compute_clocks=%0d samples=%0d done=%0d",N,max_latency,outputs,dones);
        test_passed=1; $finish;
    end
    initial begin #2000000000; $fatal(1,"engine timeout N=%0d",N); end
endmodule
