`timescale 1ns/1ps
// 相同事件、相同采样节拍的旧分档与新峰值保护对照。
// N=64验证满载吞吐；N=4/TIMBRE=2导出真实钢琴仿真试听，不播放预录音频。
module tb_sustain_neutral #(parameter N=64,TIMBRE=0,LONG_DEMO=0);
    reg clk=0;
    always #5 clk=~clk;
    reg rn=0;
    reg [1:0] valid_command=0;
    reg command_on=1;
    reg [5:0] voice=0;
    reg [6:0] note=69;
    wire [1:0] command_ready,sample_valid,done_valid;
    wire [5:0] done_old,done_new;
    wire signed [23:0] old_l,old_r,new_l,new_r;
    integer tick=0;
    wire sample_ready=rn && tick==1023;
    always @(posedge clk)begin
        if(!rn)tick<=0;
        else tick<=tick==1023?0:tick+1;
    end
    voice_engine #(.VOICE_COUNT(N),.AUTO_HEADROOM(1),.HEADROOM_SMOOTH(1),.STABLE_CHORD_GAIN(1),
        .FM_ENABLE(1),.ATTACK_MS(0),.DECAY_MS(0),.RELEASE_MS(1)) old_engine(
        .clk(clk),.rst_n(rn),.cmd_valid(valid_command[0]),.cmd_ready(command_ready[0]),
        .cmd_on(command_on),.cmd_voice(voice),.cmd_note(note),.cmd_velocity(7'd100),.cmd_timbre(TIMBRE[1:0]),
        .done_valid(done_valid[0]),.done_ready(1'b1),.done_voice(done_old),
        .sample_valid(sample_valid[0]),.sample_ready(sample_ready),.sample_left(old_l),.sample_right(old_r),
        .active_gain(12'd2048),.active_bend_cents(13'sd0),.active_vibrato_cents(8'd0));
    wire gate_valid,gate_ready,gate_on;
    wire [5:0] gate_voice;wire [6:0] gate_note,gate_velocity;wire [1:0] gate_timbre;
    sustain_command_gate #(.VOICE_COUNT(N)) gate(.clk(clk),.rst_n(rn),.sustain_enabled(1'b0),
        .in_valid(valid_command[1]),.in_ready(command_ready[1]),.in_on(command_on),.in_voice(voice),
        .in_note(note),.in_velocity(7'd100),.in_timbre(TIMBRE[1:0]),
        .out_valid(gate_valid),.out_ready(gate_ready),.out_on(gate_on),.out_voice(gate_voice),
        .out_note(gate_note),.out_velocity(gate_velocity),.out_timbre(gate_timbre),.deferred_mask(),.deferred_count());
    voice_engine #(.VOICE_COUNT(N),.AUTO_HEADROOM(1),.HEADROOM_SMOOTH(1),.STABLE_CHORD_GAIN(1),
        .FM_ENABLE(1),.ATTACK_MS(0),.DECAY_MS(0),.RELEASE_MS(1)) new_engine(
        .clk(clk),.rst_n(rn),.cmd_valid(gate_valid),.cmd_ready(gate_ready),
        .cmd_on(gate_on),.cmd_voice(gate_voice),.cmd_note(gate_note),.cmd_velocity(gate_velocity),.cmd_timbre(gate_timbre),
        .done_valid(done_valid[1]),.done_ready(1'b1),.done_voice(done_new),
        .sample_valid(sample_valid[1]),.sample_ready(sample_ready),.sample_left(new_l),.sample_right(new_r),
        .active_gain(12'd2048),.active_bend_cents(13'sd0),.active_vibrato_cents(8'd0));
    integer frames=0,tag=0,csv,done_count=0,active_seen=0,limited=0,stall_checks=0;
    integer expected_voices=0,deadline_checks=0;
    reg first_pair=0,previous_stall=0;
    reg [47:0] previous_pcm;
    wire [16:0] limiter_gain=new_engine.g_peak_limiter.limiter_gain;
    always @(posedge clk)if(rn)begin
        if(previous_stall && (!sample_valid[1] || {new_l,new_r}!==previous_pcm))
            $fatal(1,"stable chord PCM moved under backpressure");
        previous_stall<=sample_valid[1] && !sample_ready;
        previous_pcm<={new_l,new_r};
        if(sample_valid[1] && !sample_ready)stall_checks=stall_checks+1;
        if(done_valid[1])done_count=done_count+1;
        if(sample_ready)begin
            if(first_pair && sample_valid!=3)$fatal(1,"missed 1024-cycle deadline N=%d valid=%b",N,sample_valid);
            if(sample_valid==3)begin
                if({old_l,old_r}!=={new_l,new_r})$fatal(1,"neutral PCM difference frame=%0d",frames);
                first_pair=1;
                frames=frames+1;
                deadline_checks=deadline_checks+1;
                if((^{old_l,old_r,new_l,new_r})===1'bx)$fatal(1,"unknown chord PCM");
                if($signed(new_l)>4194303 || $signed(new_l)< -4194303 ||
                   $signed(new_r)>4194303 || $signed(new_r)< -4194303)$fatal(1,"new mix peak exceeded ceiling");
                if(new_engine.g_peak_limiter.limiting)limited=limited+1;
                if(new_engine.frame_active_count==N)active_seen=active_seen+1;
                if((tag==1 || tag==3) && limiter_gain!=65536)$fatal(1,"normal one/two notes unexpectedly compressed");
                $fdisplay(csv,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",frames,tag,
                    $signed(old_l),$signed(old_r),$signed(new_l),$signed(new_r),
                    new_engine.frame_active_count,limiter_gain,16'd0);
            end
        end
    end else begin first_pair<=0;previous_stall<=0;end
    task cycles(input integer n);
        repeat(n)@(negedge clk);
    endtask
    task frame_wait(input integer count);
        integer target;
        begin target=frames+count;while(frames<target)@(negedge clk);end
    endtask
    task command(input integer on_value,id,pitch);
        reg [1:0] pending;
        begin
            while(tick<128 || tick>512)cycles(1);
            @(negedge clk);
            command_on=on_value;voice=id;note=pitch;pending=3;valid_command=pending;
            while(pending!=0)begin
                @(posedge clk);pending=pending & ~command_ready;
                @(negedge clk);valid_command=pending;
            end
        end
    endtask
    integer i,timeout;
    initial begin
        if(TIMBRE==2)csv=$fopen("sim/audio_results/sustain_neutral_piano.csv","w");
        else csv=$fopen("sim/audio_results/sustain_neutral_sine.csv","w");
        $fdisplay(csv,"frame,stage,old_left,old_right,new_left,new_right,voices,limiter_gain_q16,old_boost_q10");
        cycles(5);rn=1;frame_wait(5);
        command(1,0,69);frame_wait(128);
        tag=1;frame_wait(LONG_DEMO?19200:2048);
        tag=2;command(1,1,76);frame_wait(128);
        tag=3;frame_wait(LONG_DEMO?19200:2048);
        tag=4;
        for(i=2;i<N;i=i+1)command(1,i,36+i);
        frame_wait(256);
        tag=5;frame_wait(1024);
        if(active_seen<100)$fatal(1,"missing full voice coverage");
        tag=6;
        for(i=1;i<N;i=i+1)command(0,i,0);
        frame_wait(1200);
        tag=7;frame_wait(128);
        command(0,0,0);frame_wait(1200);
        if(done_count!=N || new_engine.frame_active_count!=0)$fatal(1,"release/recycle failed done=%d",done_count);
        if(new_l!=0 || new_r!=0)$fatal(1,"release did not become silent");
        if(deadline_checks<3000 || stall_checks<1000)$fatal(1,"insufficient continuity/stall coverage");
        $fclose(csv);
        $display("SUSTAIN NEUTRAL PASS N=%0d TIMBRE=%0d frames=%0d full_voice_frames=%0d limited=%0d done=%0d stalls=%0d",N,TIMBRE,frames,active_seen,limited,done_count,stall_checks);
        $finish;
    end
    initial begin #1000000000;$fatal(1,"chord mix timeout N=%0d frames=%0d",N,frames);end
endmodule
