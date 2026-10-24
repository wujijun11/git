`timescale 1ns/1ps
// Compare real 64-voice PCM with the legacy fixed-headroom engine. The
// independent frame scoreboard includes release tails, not held-note count.
// Shortened ADSR timings accelerate this logic test; they are not board presets.
module tb_voice_headroom;
    reg test_passed=0;
    reg clk=0, rst_n=0;
    always #10 clk=~clk;
    reg cmd_valid=0, cmd_on=0;
    reg [5:0] cmd_voice=0;
    reg [6:0] cmd_note=69, cmd_velocity=127;
    reg [1:0] cmd_timbre=0;
    reg [11:0] active_gain=2048;
    wire old_ready,new_ready,old_valid,new_valid,old_done,new_done;
    wire [5:0] old_done_voice,new_done_voice;
    wire signed [23:0] old_l,old_r,new_l,new_r;
    wire old_begin,new_begin;
    reg [2:0] output_hold=0;
    wire sample_ready=rst_n && output_hold==3;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) output_hold<=0;
        else if(old_valid) begin
            if(sample_ready) output_hold<=0;
            else output_hold<=output_hold+1'b1;
        end
    end

    // PAN_SPREAD=0 removes voice-index-dependent gain from the comparison.
    voice_engine #(.VOICE_COUNT(64),.AUTO_HEADROOM(0),.PAN_SPREAD(0),
        .ATTACK_MS(0),.DECAY_MS(0),.RELEASE_MS(1),.FX_ENABLE(0)) baseline(
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(old_ready),
        .cmd_on(cmd_on),.cmd_voice(cmd_voice),.cmd_note(cmd_note),
        .cmd_velocity(cmd_velocity),.cmd_timbre(cmd_timbre),
        .done_valid(old_done),.done_ready(1'b1),.done_voice(old_done_voice),
        .sample_valid(old_valid),.sample_ready(sample_ready),
        .sample_left(old_l),.sample_right(old_r),.engine_sample_begin(old_begin),
        .active_gain(active_gain),.active_bend_cents(13'sd0),
        .active_vibrato_cents(8'd0));
    voice_engine #(.VOICE_COUNT(64),.AUTO_HEADROOM(1),.PAN_SPREAD(0),
        .ATTACK_MS(0),.DECAY_MS(0),.RELEASE_MS(1),.FX_ENABLE(0)) dut(
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(new_ready),
        .cmd_on(cmd_on),.cmd_voice(cmd_voice),.cmd_note(cmd_note),
        .cmd_velocity(cmd_velocity),.cmd_timbre(cmd_timbre),
        .done_valid(new_done),.done_ready(1'b1),.done_voice(new_done_voice),
        .sample_valid(new_valid),.sample_ready(sample_ready),
        .sample_left(new_l),.sample_right(new_r),.engine_sample_begin(new_begin),
        .active_gain(active_gain),.active_bend_cents(13'sd0),
        .active_vibrato_cents(8'd0));

    function integer boost_for_count(input integer n);
        begin
            if(n<=1) boost_for_count=64;
            else if(n<=2) boost_for_count=32;
            else if(n<=4) boost_for_count=16;
            else if(n<=8) boost_for_count=8;
            else if(n<=16) boost_for_count=4;
            else if(n<=32) boost_for_count=2;
            else boost_for_count=1;
        end
    endfunction
    function integer abs_i(input integer n);
        begin abs_i=n<0 ? -n:n; end
    endfunction

    integer cycles=0,frames_seen=0,pcm_checks=0,stall_checks=0,release_scans=0;
    integer observed_count=0,frame_count=0,frame_boost=1;
    integer pcm,stage_tag=0,note_tag=-1;
    integer expected_l,expected_r,delta_l,delta_r,limit,peak=0;
    integer coverage[0:64];
    reg previous_stall=0;
    reg [47:0] held_old,held_new;
    reg require_mute=0;
    integer j;
    initial for(j=0;j<=64;j=j+1) coverage[j]=0;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>5000000) $fatal(1,"VOICE HEADROOM watchdog");
        if(!rst_n) begin
            observed_count=0;frame_count=0;frame_boost=1;previous_stall=0;
        end else begin
            if(old_ready!==new_ready || old_valid!==new_valid || old_begin!==new_begin)
                $fatal(1,"headroom changed command/sample scheduling");
            if(old_done!==new_done || (old_done && old_done_voice!==new_done_voice))
                $fatal(1,"headroom changed release/completion scheduling");
            if(previous_stall) begin
                if(!old_valid || !new_valid || {old_l,old_r}!==held_old ||
                    {new_l,new_r}!==held_new) $fatal(1,"PCM changed under backpressure");
                stall_checks=stall_checks+1;
            end
            previous_stall=old_valid && !sample_ready;
            held_old={old_l,old_r};held_new={new_l,new_r};
            if(baseline.state==baseline.PREP) observed_count=0;
            if(baseline.state==baseline.V_CALC && baseline.r_active) begin
                observed_count=observed_count+1;
                if(baseline.r_stage==4) release_scans=release_scans+1;
            end
            if(baseline.state==baseline.FX_SEND && baseline.fx_ready) begin
                frame_count=observed_count;
                frame_boost=boost_for_count(frame_count);
                if(dut.frame_active_count!==frame_count)
                    $fatal(1,"release-inclusive frame count got=%0d expected=%0d",dut.frame_active_count,frame_count);
                // Zero-voice shift can be zero or six; PCM must remain zero.
                if(frame_count!=0 && (1<<dut.frame_boost_shift)!=frame_boost)
                    $fatal(1,"boost boundary count=%0d shift=%0d expected factor=%0d",frame_count,dut.frame_boost_shift,frame_boost);
                if(frame_count*frame_boost>64) $fatal(1,"coherent gain budget exceeded");
                coverage[frame_count]=coverage[frame_count]+1;
            end
            if(old_valid && sample_ready) begin
                frames_seen=frames_seen+1;
                if((^{old_l,old_r,new_l,new_r})===1'bx) $fatal(1,"unknown PCM");
                if(new_l==24'sh7fffff || new_l==24'sh800000 ||
                    new_r==24'sh7fffff || new_r==24'sh800000) $fatal(1,"24-bit output clipped");
                expected_l=$signed(old_l)*frame_boost;
                expected_r=$signed(old_r)*frame_boost;
                delta_l=$signed(new_l)-expected_l;
                delta_r=$signed(new_r)-expected_r;
                // Gain is rounded once after boosting; multiplying already
                // rounded legacy PCM differs by at most one factor-sized LSB.
                limit=frame_boost+2;
                if(abs_i(delta_l)>limit || abs_i(delta_r)>limit)
                    $fatal(1,"PCM factor mismatch frame=%0d count=%0d factor=%0d old=%0d new=%0d delta=%0d",frames_seen,frame_count,frame_boost,$signed(old_l),$signed(new_l),delta_l);
                if(require_mute && (old_l!=0 || old_r!=0 || new_l!=0 || new_r!=0))
                    $fatal(1,"gain zero did not mute after smoothing settled");
                if(abs_i($signed(new_l))>peak) peak=abs_i($signed(new_l));
                if(abs_i($signed(new_r))>peak) peak=abs_i($signed(new_r));
                pcm_checks=pcm_checks+1;
                $fdisplay(pcm,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",frames_seen,stage_tag,note_tag,frame_count,frame_boost,baseline.frame_gain,$signed(old_l),$signed(old_r),$signed(new_l),$signed(new_r));
            end
        end
    end

    task frames(input integer count);
        integer k;
        begin
            for(k=0;k<count;k=k+1) begin
                do @(posedge clk); while(!(old_valid && sample_ready));
                @(negedge clk);
            end
        end
    endtask
    task send_command(input bit on_value,input integer voice,note);
        begin
            @(negedge clk);
            while(!old_ready || !new_ready) @(negedge clk);
            cmd_on=on_value;cmd_voice=voice;cmd_note=note;cmd_valid=1;
            @(posedge clk);
            if(!old_ready || !new_ready) $fatal(1,"command ready unexpectedly changed");
            @(negedge clk);cmd_valid=0;
            wait(!baseline.pending_command && !dut.pending_command);
            @(negedge clk);
        end
    endtask
    task check_steady(input integer n);
        integer before_frames,nonzero;
        begin
            frames(3);
            if(frame_count!=n) $fatal(1,"steady active count expected=%0d actual=%0d",n,frame_count);
            before_frames=frames_seen;nonzero=0;
            repeat(24) begin
                frames(1);
                if(new_l!=0 || new_r!=0) nonzero=nonzero+1;
            end
            if(nonzero<8) $fatal(1,"steady PCM unexpectedly silent count=%0d",n);
            $display("HEADROOM STEADY PASS voices=%0d boost=%0d samples=%0d",n,boost_for_count(n),frames_seen-before_frames);
        end
    endtask

    integer n,k,pitch_checks=0;
    reg [31:0] expected_ftw,previous_ftw=0;
    real hz,ftw_real;
    string pcm_path;
    initial begin
        if(!$value$plusargs("PCM=%s",pcm_path)) pcm_path="voice_headroom_pcm.csv";
        pcm=$fopen(pcm_path,"w");
        if(!pcm) $fatal(1,"cannot create PCM evidence");
        $fdisplay(pcm,"frame,stage,midi,active_count,boost,gain_q1_11,old_left,old_right,new_left,new_right");
        repeat(5) @(negedge clk);rst_n=1;frames(3);
        // Incremental build exercises every transition as well as the named
        // steady-state powers of two; there are no forced internal states.
        for(n=1;n<=64;n=n+1) begin
            stage_tag=n;
            send_command(1,n-1,36+(n-1));
            if(n==1 || n==2 || n==4 || n==8 || n==16 || n==32 || n==64)
                check_steady(n);
        end
        stage_tag=100;active_gain=4095;frames(260);check_steady(64);
        if(baseline.frame_gain!=4095 || dut.frame_gain!=4095) $fatal(1,"maximum expression gain not reached");
        // Release one full-level voice. The first ten tail frames still count
        // all 64 voices, even though only 63 keys remain held.
        stage_tag=200;send_command(0,63,99);frames(10);
        if(frame_count!=64) $fatal(1,"release tail removed from headroom count early");
        for(k=0;k<63;k=k+1) send_command(0,k,36+k);
        frames(55);
        if(frame_count!=0 || new_l!=0 || new_r!=0) $fatal(1,"release did not reach silence");
        if(release_scans<100) $fatal(1,"release-tail coverage insufficient");

        stage_tag=300;send_command(1,0,60);frames(3);check_steady(1);
        active_gain=0;frames(515);require_mute=1;frames(8);
        if(baseline.frame_gain!=0 || dut.frame_gain!=0) $fatal(1,"zero gain not reached");
        require_mute=0;
        // Independent equal-tempered formula checks actual command->ROM->RAM
        // and bent FTW, so 25 distinct addresses cannot pass using a copied LUT.
        stage_tag=400;
        for(n=60;n<=84;n=n+1) begin
            note_tag=n;send_command(1,0,n);frames(2);
            hz=440.0*$pow(2.0,(n-69)/12.0);
            ftw_real=hz*4294967296.0/48000.0;
            expected_ftw=$rtoi(ftw_real+0.5);
            if(abs_i($signed(baseline.u_state.mem[0][63:32])-$signed(expected_ftw))>1 ||
                dut.u_state.mem[0][63:32]!==baseline.u_state.mem[0][63:32])
                $fatal(1,"MIDI pitch RAM mismatch note=%0d FTW=%0h expected=%0h",n,dut.u_state.mem[0][63:32],expected_ftw);
            if(n>60 && dut.u_state.mem[0][63:32]<=previous_ftw) $fatal(1,"MIDI FTW not strictly increasing");
            wait(dut.state==dut.V_ADDR && dut.voice_id==0);@(negedge clk);
            if(abs_i($signed(dut.effective_ftw)-$signed(expected_ftw))>1)
                $fatal(1,"MIDI pitch did not reach oscillator note=%0d actual=%0h expected=%0h",n,dut.effective_ftw,expected_ftw);
            previous_ftw=dut.u_state.mem[0][63:32];pitch_checks=pitch_checks+1;
            $display("HEADROOM PITCH PASS midi=%0d hz=%0.6f ftw=%0h",n,hz,previous_ftw);
        end
        // Maximum-gain mono was already measured before the mute sweep.
        // Keep the pitch scan muted rather than repeat another 512-frame ramp.
        stage_tag=500;require_mute=1;frames(8);require_mute=0;
        for(n=1;n<=64;n=n*2) if(coverage[n]<20) $fatal(1,"missing active-count coverage %0d",n);
        if(stall_checks<100 || pcm_checks<1000 || pitch_checks!=25) $fatal(1,"incomplete test coverage");
        $fclose(pcm);test_passed=1;
        $display("VOICE HEADROOM PASSED pcm=%0d stall_checks=%0d release_scans=%0d pitch_checks=%0d peak=%0d cycles=%0d",pcm_checks,stall_checks,release_scans,pitch_checks,peak,cycles);
        $finish;
    end
endmodule
