`timescale 1ns/1ps
// C4--C6 V2-event audition of the SAME optional 2-operator FM RTL.
// Sequential one-note clips use VOICE_COUNT=4 for fast simulation; the
// separate FM regression exercises 64 simultaneous logical voices.
module tb_fm_keyboard;
    parameter TIMBRE=3;
    parameter HOLD_FRAMES=7680;    // Override for longer piano listening clips.
    parameter RELEASE_FRAMES=5760;
    reg test_passed=0;
    reg clk=0, rst_n=0;
    always #10 clk=~clk; // accelerated simulation, not board timing evidence

    reg event_valid=0, event_on=0;
    wire event_ready;
    reg [6:0] event_note=60, event_velocity=100;
    wire cmd_valid,cmd_ready,cmd_on,done_valid,done_ready;
    wire [5:0] cmd_voice,done_voice;
    wire [6:0] cmd_note,cmd_velocity,active_count;
    wire [1:0] cmd_timbre;
    wire [63:0] active_mask,held_mask;
    wire full_pulse,ignored_pulse,done_error_pulse;
    wire sample_begin,expr_ready,expr_applied;
    wire [11:0] active_gain;
    wire signed [12:0] active_bend;
    wire [7:0] active_vibrato;
    captain_control_top_v2 captain(
        .clk(clk),.rst_n(rst_n),.event_valid(event_valid),.event_ready(event_ready),
        .event_on(event_on),.event_source(6'd0),.event_note(event_note),
        .event_velocity(event_velocity),.event_timbre(TIMBRE[1:0]),
        .expr_valid(1'b0),.expr_ready(expr_ready),.expr_gain(12'd2048),
        .expr_bend_cents(13'sd0),.expr_vibrato_cents(8'd0),
        .engine_sample_begin(sample_begin),.active_gain(active_gain),
        .active_bend_cents(active_bend),.active_vibrato_cents(active_vibrato),
        .expr_applied(expr_applied),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
        .cmd_on(cmd_on),.cmd_voice(cmd_voice),.cmd_note(cmd_note),
        .cmd_velocity(cmd_velocity),.cmd_timbre(cmd_timbre),
        .done_valid(done_valid),.done_ready(done_ready),.done_voice(done_voice),
        .active_count(active_count),.active_mask(active_mask),.held_mask(held_mask),
        .full_pulse(full_pulse),.ignored_pulse(ignored_pulse),
        .done_error_pulse(done_error_pulse)
    );

    wire sample_valid;
    // Intentionally hold every output for three clocks, including note tails,
    // so the valid/PCM stability assertion is exercised deterministically.
    reg [1:0] forced_hold=0;
    wire sample_ready=rst_n && forced_hold==3;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) forced_hold<=0;
        else if(sample_valid) begin
            if(sample_ready) forced_hold<=0;
            else forced_hold<=forced_hold+1'b1;
        end
    end
    wire signed [23:0] sample_left,sample_right;
    voice_engine #(.VOICE_COUNT(4),.FM_ENABLE(1),.FX_ENABLE(0)) engine(
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
        .cmd_on(cmd_on),.cmd_voice(cmd_voice),.cmd_note(cmd_note),
        .cmd_velocity(cmd_velocity),.cmd_timbre(cmd_timbre),
        .done_valid(done_valid),.done_ready(done_ready),.done_voice(done_voice),
        .sample_valid(sample_valid),.sample_ready(sample_ready),
        .sample_left(sample_left),.sample_right(sample_right),
        .engine_sample_begin(sample_begin),.active_gain(active_gain),
        .active_bend_cents(active_bend),.active_vibrato_cents(active_vibrato)
    );

    integer outputs=0,done_count=0,stalls=0,events=0;
    integer fd=0,manifest=0,captured=0,current_note=-1,baseline_done=0;
    reg capture=0,was_stalled=0;
    reg [47:0] stalled_pcm=0;
    always @(posedge clk) begin
        if(!rst_n) begin
            outputs=0; done_count=0; was_stalled=0;
        end else begin
            if(full_pulse || ignored_pulse || done_error_pulse)
                $fatal(1,"FM keyboard allocator protocol error note=%0d",current_note);
            if(was_stalled && (!sample_valid || {sample_left,sample_right}!==stalled_pcm))
                $fatal(1,"FM keyboard PCM changed under backpressure");
            was_stalled=sample_valid && !sample_ready;
            stalled_pcm={sample_left,sample_right};
            if(was_stalled) stalls=stalls+1;
            if(done_valid && done_ready) done_count=done_count+1;
            if(sample_valid && sample_ready) begin
                if((^{sample_left,sample_right})===1'bx)
                    $fatal(1,"FM keyboard unknown PCM note=%0d",current_note);
                if(sample_left==24'sh7fffff || sample_left==24'sh800000 ||
                   sample_right==24'sh7fffff || sample_right==24'sh800000)
                    $fatal(1,"FM keyboard clipped PCM note=%0d",current_note);
                outputs=outputs+1;
                if(capture) begin
                    $fdisplay(fd,"%0d,%0d,%0d",captured,sample_left,sample_right);
                    captured=captured+1;
                end
            end
        end
    end

    task frames(input integer count);
        integer target;
        begin target=outputs+count; wait(outputs>=target); @(negedge clk); end
    endtask
    task send_note(input bit on_value,input integer midi);
        begin
            @(negedge clk);
            event_valid=1; event_on=on_value; event_note=midi;
            event_velocity=on_value ? 7'd100 : 7'd0;
            do @(posedge clk); while(!event_ready);
            events=events+1;
            @(negedge clk); event_valid=0;
        end
    endtask
    integer midi;
    initial begin
        manifest=$fopen("sim/fm_keyboard_pcm/manifest.csv","w");
        if(!manifest) $fatal(1,"cannot open FM keyboard manifest");
        $fdisplay(manifest,"midi,frames,events,done_count,fx,velocity");
        repeat(4) @(negedge clk);
        rst_n=1;
        frames(8);
        if(active_count!=0 || sample_left!==0 || sample_right!==0)
            $fatal(1,"FM keyboard reset not silent");
        for(midi=60;midi<=84;midi=midi+1) begin
            current_note=midi;
            baseline_done=done_count;
            captured=0;
            fd=$fopen($sformatf("sim/fm_keyboard_pcm/note_%02d.csv",midi),"w");
            if(!fd) $fatal(1,"cannot open FM keyboard note %0d",midi);
            $fdisplay(fd,"sample,left,right");
            capture=1;
            send_note(1,midi);
            frames(HOLD_FRAMES);
            if(active_count!=1 || held_mask==0)
                $fatal(1,"FM keyboard note-on not held note=%0d count=%0d",midi,active_count);
            send_note(0,midi);
            frames(RELEASE_FRAMES);
            if(active_count!=0 || held_mask!=0 || done_count!=baseline_done+1)
                $fatal(1,"FM keyboard voice not recycled note=%0d active=%0d done=%0d",midi,active_count,done_count);
            if(sample_left>16 || sample_left < -16 || sample_right>16 || sample_right < -16)
                $fatal(1,"FM keyboard tail did not fade note=%0d",midi);
            capture=0;
            $fclose(fd);
            $fdisplay(manifest,"%0d,%0d,%0d,%0d,0,100",midi,captured,events,done_count);
            $display("FM KEYBOARD NOTE PASSED midi=%0d frames=%0d",midi,captured);
        end
        $fclose(manifest);
        if(events!=50 || done_count!=25 || stalls==0)
            $fatal(1,"FM keyboard event/done/stall count mismatch events=%0d done=%0d stalls=%0d",events,done_count,stalls);
        $display("FM KEYBOARD PASSED: C4-C6, 25 notes, 50 events, 25 releases, stalls=%0d",stalls);
        test_passed=1;
        $finish;
    end
    initial begin #(30.0e9); $fatal(1,"FM keyboard timeout"); end
endmodule
