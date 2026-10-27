`timescale 1ns/1ps
// 同命令驱动两份真实HDL音源；N=4导出钢琴对比，N=64检验生产释放时间。
// 逻辑输出间隔固定1024拍，PCM时间按48000样本/秒解释，不把仿真加速时钟当板测。
module tb_headroom_smoothing #(parameter N=4);
    reg clk=0;
    always #5 clk=~clk;
    reg rn=0,cv=0,on_value=0;
    reg [5:0] voice=0;
    reg [6:0] note=60;
    reg [11:0] expression_gain=2048;
    wire [1:0] cr,sv,dv;
    wire [5:0] done_old,done_new;
    wire signed [23:0] old_l,old_r,new_l,new_r;
    reg [9:0] sample_timer=0;
    wire ready=sample_timer==1023;
    always @(posedge clk)if(!rn)sample_timer<=0;
    else sample_timer<=sample_timer+1'b1;
    voice_engine #(.VOICE_COUNT(N),.FM_ENABLE(1),.AUTO_HEADROOM(1)) old_engine(
        .clk(clk),.rst_n(rn),.cmd_valid(cv),.cmd_ready(cr[0]),.cmd_on(on_value),
        .cmd_voice(voice),.cmd_note(note),.cmd_velocity(7'd96),.cmd_timbre(2'd2),
        .done_valid(dv[0]),.done_ready(1'b1),.done_voice(done_old),.sample_valid(sv[0]),.sample_ready(ready),
        .sample_left(old_l),.sample_right(old_r),.engine_sample_begin(),
        .active_gain(expression_gain),.active_bend_cents(13'sd0),.active_vibrato_cents(8'd0));
    voice_engine #(.VOICE_COUNT(N),.FM_ENABLE(1),.AUTO_HEADROOM(1),.HEADROOM_SMOOTH(1)) new_engine(
        .clk(clk),.rst_n(rn),.cmd_valid(cv),.cmd_ready(cr[1]),.cmd_on(on_value),
        .cmd_voice(voice),.cmd_note(note),.cmd_velocity(7'd96),.cmd_timbre(2'd2),
        .done_valid(dv[1]),.done_ready(1'b1),.done_voice(done_new),.sample_valid(sv[1]),.sample_ready(ready),
        .sample_left(new_l),.sample_right(new_r),.engine_sample_begin(),
        .active_gain(expression_gain),.active_bend_cents(13'sd0),.active_vibrato_cents(8'd0));
    integer frames=0,pcm,stalls=0,done_count=0,clips=0,tag=0;
    integer saved_count,saved_shift,saved_gain,saved_master,saved_raw_l,saved_raw_r,saved_guard;
    reg previous_stall=0;
    reg [47:0] held_old,held_new;
    always @(posedge clk)if(rn)begin
        if(cr[0]!==cr[1] || sv[0]!==sv[1] || dv[0]!==dv[1] ||
            (dv[0] && done_old!==done_new))$fatal(1,"changed cmd/sample/done scheduling");
        if(previous_stall)begin
            if(!sv[0] || {old_l,old_r}!==held_old || {new_l,new_r}!==held_new)$fatal(1,"PCM moved under stall");
            stalls=stalls+1;
        end
        held_old={old_l,old_r};
        held_new={new_l,new_r};
        previous_stall=sv[0] && !ready;
        if(dv[0])done_count=done_count+1;
        if(new_engine.state==new_engine.FX_SEND)begin
            saved_count=new_engine.frame_active_count;
            saved_shift=new_engine.frame_boost_shift;
            saved_gain=new_engine.g_smooth_headroom.applied_gain_q10;
            saved_master=new_engine.frame_gain;
            saved_raw_l=new_engine.mix_left;
            saved_raw_r=new_engine.mix_right;
            saved_guard=new_engine.g_smooth_headroom.peak_guard;
        end
        if(ready && frames>4 && !sv[0])$fatal(1,"missed 1024-cycle deadline");
        if(sv[0] && ready)begin
            frames=frames+1;
            if((^{old_l,old_r,new_l,new_r})===1'bx)$fatal(1,"unknown PCM");
            if(new_l==24'sh7fffff || new_l==24'sh800000 || new_r==24'sh7fffff || new_r==24'sh800000)clips=clips+1;
            if(saved_gain==1024*(1<<saved_shift) && !saved_guard && (old_l!==new_l || old_r!==new_r))
                $fatal(1,"steady PCM not bit exact frame=%0d",frames);
            $fdisplay(pcm,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",frames,tag,
                $signed(old_l),$signed(old_r),$signed(new_l),$signed(new_r),saved_count,saved_shift,saved_gain,saved_master,saved_raw_l,saved_raw_r,saved_guard);
        end
    end
    task command(input integer is_on,id,pitch);
        begin @(negedge clk);
        on_value=is_on;
        voice=id;
        note=pitch;
        cv=1;
            do @(posedge clk);
            while(!cr[0]);
            @(negedge clk);
            cv=0;
            wait(!old_engine.pending_command);
            @(negedge clk);
            end
    endtask
    task wait_frames(input integer count);
        integer target;
        begin target=frames+count;
        wait(frames>=target);
        @(negedge clk);
        end
    endtask
    integer n;
    string path;
    initial begin
        path=N==4?"sim/audio_results/headroom_smoothing_n4.csv":"sim/audio_results/headroom_smoothing_n64.csv";
        pcm=$fopen(path,"w");
        if(!pcm)$fatal(1,"cannot create PCM capture");
        $fdisplay(pcm,"frame,tag,old_l,old_r,new_l,new_r,active,shift,gain_q10,master_gain,raw_l,raw_r,guard");
        repeat(5)@(negedge clk);
        rn=1;
        wait_frames(3);
        if(N==4)begin
            tag=1;
            command(1,0,60);
            wait_frames(1500);
            tag=2;
            command(1,1,64);
            wait_frames(1500);
            tag=3;
            command(0,1,64);
            wait_frames(5500);
            tag=4;
            command(1,0,60);
            wait_frames(1500);
            tag=5;
            command(0,0,60);
            wait_frames(5500);
            wait_frames(500);
        end else begin
            for(n=0;n<64;n=n+1)begin tag=n+1;
            command(1,n,36+n);
            end
            wait_frames(100);
            expression_gain=4095;
            wait_frames(300);
            if(new_engine.frame_active_count!=64)$fatal(1,"64 voices not active");
            tag=100;
            for(n=0;n<64;n=n+1)command(0,n,36+n);
            wait_frames(5000);
            if(done_count!=64 || new_engine.frame_active_count!=0)$fatal(1,"64 release completion missing");
            if(new_l || new_r)$fatal(1,"release not silent");
        end
        if(clips || stalls<1000)$fatal(1,"clipping or insufficient stalls");
        $fclose(pcm);
        $display("HEADROOM SMOOTHING PASS N=%0d frames=%0d stalls=%0d done=%0d clips=%0d, unchanged steady scale and scheduling",N,frames,stalls,done_count,clips);
        $finish;
    end
    initial begin #250000000;
    $fatal(1,"integration timeout");
    end
endmodule
