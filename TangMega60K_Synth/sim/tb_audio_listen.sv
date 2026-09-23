`timescale 1ns/1ps
// Offline audition: original 64-voice engine + V2 allocator, sample handshake
// captured at its native 48 kHz sample index. No second synthesizer / audio ROM.
// No I2S in this bench: existing I2S serialization was verified separately.
module tb_audio_listen;
    parameter FX=0;
    parameter PIANO=0;
    parameter POLAR_QUICK=0;
    parameter FM=0;
    reg test_passed=0;
    reg clk=0,rst_n=0;
    always #10 clk=~clk; // accelerated logical scheduling, NOT board clock evidence
    reg ev=0,eon=0;
    wire er;
    reg [6:0] enote=69,evel=100;
    reg [1:0] etimbre=0;
    reg xv=0;
    wire xr,applied;
    reg [11:0] gain=2048;
    reg signed [12:0] bend=0;
    reg [7:0] depth=0;
    wire begin_frame;
    wire [11:0] active_gain;
    wire signed [12:0] active_bend;
    wire [7:0] active_depth;
    wire cv,cr,co,dv,dr;
    wire [5:0] voice,dvoice;
    wire [6:0] note,velocity,active_count;
    wire [1:0] timbre;
    wire [63:0] active_mask,held_mask;
    wire full_pulse,ignored_pulse,done_error;
    captain_control_top_v2 captain(.clk(clk),.rst_n(rst_n),
        .event_valid(ev),.event_ready(er),.event_on(eon),.event_source(6'd0),
        .event_note(enote),.event_velocity(evel),.event_timbre(etimbre),
        .expr_valid(xv),.expr_ready(xr),.expr_gain(gain),.expr_bend_cents(bend),
        .expr_vibrato_cents(depth),.engine_sample_begin(begin_frame),
        .active_gain(active_gain),.active_bend_cents(active_bend),.active_vibrato_cents(active_depth),
        .expr_applied(applied),.cmd_valid(cv),.cmd_ready(cr),.cmd_on(co),.cmd_voice(voice),
        .cmd_note(note),.cmd_velocity(velocity),.cmd_timbre(timbre),
        .done_valid(dv),.done_ready(dr),.done_voice(dvoice),.active_count(active_count),
        .active_mask(active_mask),.held_mask(held_mask),.full_pulse(full_pulse),
        .ignored_pulse(ignored_pulse),.done_error_pulse(done_error));
    reg [5:0] pacing=0;
    always @(posedge clk) pacing<=pacing+1'b1;
    wire sv;
    wire sready=rst_n && pacing!=0;
    wire signed [23:0] sl,sr;
    voice_engine #(.VOICE_COUNT(64),.FX_ENABLE(FX),.FM_ENABLE(FM)) engine(
        .clk(clk),.rst_n(rst_n),.cmd_valid(cv),.cmd_ready(cr),.cmd_on(co),.cmd_voice(voice),
        .cmd_note(note),.cmd_velocity(velocity),.cmd_timbre(timbre),
        .done_valid(dv),.done_ready(dr),.done_voice(dvoice),
        .sample_valid(sv),.sample_ready(sready),.sample_left(sl),.sample_right(sr),
        .engine_sample_begin(begin_frame),.active_gain(active_gain),
        .active_bend_cents(active_bend),.active_vibrato_cents(active_depth));
    integer outputs=0,captured=0,fd=0,events=0,manifest=0,clip=0;
    integer i,t,held_retriggers=0,stalls=0;
    reg capture=0,previous_stall=0;
    reg [47:0] held_sample;
    always @(posedge clk) begin
        if(!rst_n) begin outputs=0; previous_stall=0; end
        else begin
            if(full_pulse || ignored_pulse || done_error) $fatal(1,"audition control error clip=%0d",clip);
            if(previous_stall && (!sv || {sl,sr}!==held_sample)) $fatal(1,"audition PCM stall");
            previous_stall=sv && !sready; held_sample={sl,sr};
            if(previous_stall) stalls=stalls+1;
            if(sv && sready) begin
                if((^{sl,sr})===1'bx) $fatal(1,"unknown audition PCM");
                if(sl==24'sh7fffff || sl==24'sh800000 || sr==24'sh7fffff || sr==24'sh800000)
                    $fatal(1,"audition sample clipped");
                outputs=outputs+1;
                if(capture) begin
                    $fdisplay(fd,"%0d,%0d,%0d",captured,sl,sr);
                    captured=captured+1;
                end
            end
        end
    end
    task frames(input integer count);
        integer target; begin target=outputs+count; wait(outputs>=target); @(negedge clk); end
    endtask
    task note_event(input bit on_value,input integer midi,input integer vel,input integer color);
        begin
            @(negedge clk); ev=1; eon=on_value; enote=midi; evel=vel; etimbre=color;
            do @(posedge clk); while(!er);
            $fdisplay(events,"%0d,note,%0d,%0d,%0d,%0d,%0d,%0d,%0d",captured,on_value,midi,vel,color,gain,bend,depth);
            @(negedge clk); ev=0;
        end
    endtask
    task expression(input integer g,input integer b,input integer d);
        begin
            @(negedge clk); xv=1; gain=g; bend=b; depth=d;
            do @(posedge clk); while(!xr);
            $fdisplay(events,"%0d,expression,0,0,0,0,%0d,%0d,%0d",captured,g,b,d);
            @(negedge clk); xv=0;
        end
    endtask
    task open_clip(input integer id);
        begin
            @(negedge clk); capture=0; rst_n=0; ev=0; xv=0; gain=2048; bend=0; depth=0;
            repeat(4) @(negedge clk); rst_n=1; frames(5);
            if(active_count!=0 || sl!==0 || sr!==0) $fatal(1,"clip reset not silent");
            clip=id; captured=0;
            fd=$fopen($sformatf("sim/listen_results/clip_%02d.csv",id),"w");
            events=$fopen($sformatf("sim/listen_results/events_%02d.csv",id),"w");
            if(!fd || !events) $fatal(1,"cannot open audition output");
            $fdisplay(fd,"sample,left,right");
            $fdisplay(events,"sample,event,on,note,velocity,timbre,gain,bend,depth");
            capture=1; frames(3840); // 80 ms digital silence before each example
        end
    endtask
    task close_clip;
        begin
            if(active_count!=0 || held_mask!=0) $fatal(1,"clip ended with unreleased voices");
            if(sl>16 || sl < -16 || sr>16 || sr < -16) $fatal(1,"clip ended before tail faded");
            capture=0; $fclose(fd); $fclose(events);
            $fdisplay(manifest,"%0d,%0d,%0d",clip,captured,FX);
            $display("LISTEN CLIP PASSED id=%0d samples=%0d fx=%0d",clip,captured,FX);
        end
    endtask
    function integer scale_note(input integer index);
        case(index)
            0:scale_note=60; 1:scale_note=62; 2:scale_note=64; 3:scale_note=65;
            4:scale_note=67; 5:scale_note=69; 6:scale_note=71; default:scale_note=72;
        endcase
    endfunction
    function integer melody_note(input integer index);
        case(index) 0:melody_note=60; 1:melody_note=64; 2:melody_note=67; default:melody_note=72; endcase
    endfunction
    task delay_pattern;
        begin
            note_event(1,72,100,1); frames(3840); note_event(0,72,100,1); frames(9600);
            note_event(1,79,100,1); frames(3840); note_event(0,79,100,1); frames(34560);
        end
    endtask
    initial begin
        manifest=$fopen($sformatf("sim/listen_results/manifest_fx%0d.csv",FX),"w");
        if(!manifest) $fatal(1,"cannot open manifest");
        $fdisplay(manifest,"clip,samples,fx");
        if(PIANO==2) begin
            open_clip(20); note_event(1,69,100,3); frames(24000);
            note_event(0,69,0,3); frames(7200); close_clip();
            open_clip(21); note_event(1,69,40,3); frames(14400);
            note_event(0,69,0,3); frames(7200); close_clip();
            open_clip(22); note_event(1,69,127,3); frames(14400);
            note_event(0,69,0,3); frames(7200); close_clip();
            open_clip(23);
            for(i=36;i<100;i=i+1) note_event(1,i,100,3);
            frames(2400); if(active_count!=64) $fatal(1,"FM full load missing voices");
            for(i=36;i<100;i=i+1) note_event(0,i,0,3);
            frames(7200); close_clip();
            if(stalls==0) $fatal(1,"FM PCM backpressure not exercised");
            $display("FM LISTEN PASSED: four clips including full load; stalls=%0d",stalls);
        end else if(PIANO) begin
            // Identical musical phrase, velocity and gain; old vs new timbre.
            for(t=0;t<2;t=t+1) begin
                open_clip(10+t);
                for(i=0;i<4;i=i+1) begin
                    note_event(1,melody_note(i),100,t*2); frames(POLAR_QUICK ? 7200 : 14400);
                    note_event(0,melody_note(i),100,t*2); frames(4800);
                end
                frames(4800); close_clip();
            end
            open_clip(12);
            note_event(1,69,100,2); frames(POLAR_QUICK ? 48000 : 72000);
            note_event(0,69,100,2); frames(12000); close_clip();
            for(t=0;t<2;t=t+1) begin
                open_clip(13+t);
                note_event(1,69,t==0 ? 40 : 127,2); frames(POLAR_QUICK ? 14400 : 33600);
                note_event(0,69,0,0); frames(12000); close_clip();
            end
            open_clip(15);
            for(i=36;i<100;i=i+1) note_event(1,i,127,2);
            frames(4800);
            if(active_count!=64) $fatal(1,"piano full load missing voices");
            for(i=36;i<100;i=i+1) note_event(1,i,100,2);
            frames(4800);
            if(active_count!=64) $fatal(1,"piano retrigger allocated extra voices");
            for(i=36;i<100;i=i+1) note_event(0,i,0,0);
            frames(12000); close_clip();
            open_clip(16);
            for(i=0;i<12;i=i+1) begin
                note_event(1,60+i,100,2); frames(12); // release during 2 ms attack
                note_event(0,60+i,0,0); frames(720);
            end
            frames(6000); close_clip();
            if(stalls==0) $fatal(1,"piano test did not exercise PCM backpressure");
            $display("PIANO REGRESSION PASSED: 64 held/retrigger/recycle, early release, stalls=%0d",stalls);
        end else if(!FX) begin
            open_clip(1);
            note_event(1,69,100,0); frames(33600); note_event(0,69,100,0); frames(12000);
            close_clip();
            open_clip(2);
            for(i=0;i<8;i=i+1) begin
                note_event(1,scale_note(i),100,0); frames(7200);
                note_event(0,scale_note(i),100,0); frames(4320);
            end
            frames(3840); close_clip();
            open_clip(3);
            for(t=0;t<2;t=t+1) begin
                for(i=0;i<4;i=i+1) begin
                    note_event(1,melody_note(i),100,t); frames(7680);
                    note_event(0,melody_note(i),100,t); frames(5280);
                end
                frames(7200);
            end
            close_clip();
            open_clip(4);
            note_event(1,60,100,0); note_event(1,64,100,0); note_event(1,67,100,0); frames(19200);
            note_event(0,60,100,0); note_event(0,64,100,0); note_event(0,67,100,0); frames(7680);
            note_event(1,65,100,0); note_event(1,69,100,0); note_event(1,72,100,0); frames(19200);
            note_event(0,65,100,0); note_event(0,69,100,0); note_event(0,72,100,0); frames(12000);
            close_clip();
            open_clip(5);
            note_event(1,69,100,1);
            for(i=0;i<8;i=i+1) begin frames(3360); note_event(1,69,100,1); end
            note_event(0,69,100,1); frames(7680);
            for(i=0;i<8;i=i+1) begin
                note_event(1,69,100,1); frames(1920); note_event(0,69,100,1); frames(1680);
            end
            frames(9600); close_clip();
            open_clip(6);
            note_event(1,69,100,0); frames(9600);
            for(i=1;i<=12;i=i+1) begin expression(2048,i*100,0); frames(1920); end
            frames(7200);
            for(i=11;i>=0;i=i-1) begin expression(2048,i*100,0); frames(1920); end
            frames(7200); note_event(0,69,100,0); frames(9600); close_clip();
            open_clip(7);
            note_event(1,69,100,0); frames(12000);
            expression(2048,0,40); frames(24000);
            expression(2048,0,100); frames(24000);
            note_event(0,69,100,0); frames(12000); close_clip();
            open_clip(8); delay_pattern(); close_clip();
        end else begin open_clip(9); delay_pattern(); close_clip(); end
        $fclose(manifest);
        $display("LISTEN SIMULATION PASSED FX=%0d sample_stalls=%0d",FX,stalls);
        test_passed=1; $finish;
    end
    initial begin #(30.0e9); $fatal(1,"audition timeout"); end
endmodule
