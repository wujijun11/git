`timescale 1ns/1ps
// 4声部数字通路诊断：同一HDL钢琴、同一命令，比较自动余量与固定余量。
// 非板卡实测，不修改音色或增益算法；PCM时间由采样序号/48000确定。
module tb_headroom_audit;
    reg clk=0;
    always #5 clk=~clk;
    reg rn=0,valid=0,on_value=0;
    reg [5:0] voice=0;
    reg [6:0] note=60;
    wire [1:0] ready,sample_valid;
    wire signed [23:0] left_auto,right_auto,left_fixed,right_fixed;
    voice_engine #(.VOICE_COUNT(4),.FM_ENABLE(1),.AUTO_HEADROOM(1)) automatic_gain(
        .clk(clk),.rst_n(rn),.cmd_valid(valid),.cmd_ready(ready[0]),.cmd_on(on_value),
        .cmd_voice(voice),.cmd_note(note),.cmd_velocity(7'd96),.cmd_timbre(2'd2),
        .done_valid(),.done_ready(1'b1),.done_voice(),.sample_valid(sample_valid[0]),
        .sample_ready(1'b1),.sample_left(left_auto),.sample_right(right_auto),
        .engine_sample_begin(),.active_gain(12'd2048),.active_bend_cents(13'sd0),
        .active_vibrato_cents(8'd0));
    voice_engine #(.VOICE_COUNT(4),.FM_ENABLE(1),.AUTO_HEADROOM(0)) fixed_gain(
        .clk(clk),.rst_n(rn),.cmd_valid(valid),.cmd_ready(ready[1]),.cmd_on(on_value),
        .cmd_voice(voice),.cmd_note(note),.cmd_velocity(7'd96),.cmd_timbre(2'd2),
        .done_valid(),.done_ready(1'b1),.done_voice(),.sample_valid(sample_valid[1]),
        .sample_ready(1'b1),.sample_left(left_fixed),.sample_right(right_fixed),
        .engine_sample_begin(),.active_gain(12'd2048),.active_bend_cents(13'sd0),
        .active_vibrato_cents(8'd0));
    integer file_handle,frames=0;
    always @(posedge clk)if(rn)begin
        if(ready[0]!==ready[1] || sample_valid[0]!==sample_valid[1])
            $fatal(1,"headroom mode changed command/sample scheduling");
        if(sample_valid[0])begin
            $fwrite(file_handle,"%0d,%0d,%0d,%0d,%0d,%0d\n",frames,
                left_auto,right_auto,left_fixed,automatic_gain.frame_active_count,
                automatic_gain.frame_boost_shift);
            frames=frames+1;
        end
    end
    task command(input integer is_on,id,pitch);
        begin
            @(negedge clk);
            on_value=is_on;
            voice=id;
            note=pitch;
            valid=1;
            do @(posedge clk);while(!ready[0]);
            @(negedge clk);
            valid=0;
        end
    endtask
    initial begin
        file_handle=$fopen("sim/audio_results/headroom_audit.csv","w");
        if(!file_handle)$fatal(1,"cannot open PCM audit CSV");
        $fwrite(file_handle,"frame,left,right,fixed_left,active,boost\n");
        repeat(6)@(negedge clk);
        rn=1;
        command(1,0,60);
        wait(frames>=1500);
        command(1,1,64);
        wait(frames>=3000);
        command(0,1,64);
        wait(frames>=8500);
        command(1,0,60);
        wait(frames>=10000);
        command(0,0,60);
        wait(frames>=16000);
        $fclose(file_handle);
        $display("HEADROOM AUDIT CAPTURE PASS N=4 piano, note join/release, same-key retrigger, 16000 PCM samples");
        $finish;
    end
    initial begin #120000000;$fatal(1,"headroom capture timeout");end
endmodule
