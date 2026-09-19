`timescale 1ns/1fs
module tb_live64_spectrum;
    parameter CAPTURE_SAMPLES=262144; // 5.461333 s, true FFT bin spacing 0.183105 Hz
    reg test_passed=0;
    reg clk=0,rst_n=0,start=0,stop=0,capture=0;
    always #(1.0e9/49152000.0/2.0) clk=~clk;
    wire start_ready,busy,holding,released,error,bclk,ws,data_out;
    wire [6:0] active_count;
    wire [31:0] underruns;
    live64_system_top dut(.clk(clk),.rst_n(rst_n),.start(start),.stop(stop),
        .start_ready(start_ready),.busy(busy),.holding(holding),.released_pulse(released),
        .error(error),.active_count(active_count),.i2s_bclk(bclk),.i2s_lrclk(ws),
        .i2s_data(data_out),.underrun_count(underruns));
    reg [47:0] expected_queue[0:15];
    reg [47:0] expected_frame=0,held_sample=0;
    integer written=0,consumed=0,checked=0,captured=0,stalls=0;
    integer ons=0,offs=0,dones=0,csv,meta,i,stable_begin;
    reg previous_stall=0;
    reg [31:0] steady_underruns;
    // Scoreboard observes the normal interfaces; it never forces internal DUT state.
    always @(posedge clk) begin
        if(!rst_n) begin written=0; consumed=0; expected_frame=0; previous_stall=0; end
        else begin
            if(error) $fatal(1,"diagnostic error");
            if(previous_stall && (!dut.u_audio.sample_valid ||
                {dut.u_audio.sample_left,dut.u_audio.sample_right}!==held_sample))
                $fatal(1,"PCM changed under I2S backpressure");
            previous_stall=dut.u_audio.sample_valid && !dut.u_audio.sample_ready;
            held_sample={dut.u_audio.sample_left,dut.u_audio.sample_right};
            if(previous_stall) stalls=stalls+1;
            if(dut.event_valid && dut.event_ready) begin
                if(dut.event_on) begin
                    if(dut.event_note!=36+ons || dut.event_source!=63 || dut.event_timbre!=0)
                        $fatal(1,"wrong diagnostic on sequence");
                    ons=ons+1;
                end else begin
                    if(dut.event_note!=36+offs) $fatal(1,"wrong diagnostic off sequence");
                    offs=offs+1;
                end
            end
            if(dut.u_audio.done_valid && dut.u_audio.done_ready) dones=dones+1;
            if(capture && (active_count!=64 || dut.u_audio.u_captain.u_control.held_mask!==64'hffffffffffffffff))
                $fatal(1,"not 64 held voices during capture");
            if(dut.u_audio.sample_valid && dut.u_audio.sample_ready) begin
                if(written-consumed>=16) $fatal(1,"PCM scoreboard overflow");
                expected_queue[written%16]={dut.u_audio.sample_left,dut.u_audio.sample_right};
                written=written+1;
            end
            #0.000001;
            if(dut.u_audio.u_captain.frame_tick) begin
                if(consumed<written) begin expected_frame=expected_queue[consumed%16]; consumed=consumed+1; end
                else expected_frame=0;
            end
        end
    end
    reg previous_ws=1,locked=0;
    integer bit_number=0;
    reg [23:0] word_value=0,left_value=0;
    // Independent receiver: reconstruct signed PCM from the actual Philips I2S pins.
    always @(posedge bclk or negedge rst_n) begin
        if(!rst_n) begin previous_ws=1; locked=0; bit_number=0; checked=0; word_value=0; left_value=0; end
        else begin
            if(ws!==previous_ws) begin
                if(locked && bit_number!=31) $fatal(1,"not 32-bit I2S slots");
                locked=1; previous_ws=ws; bit_number=0; word_value=0;
            end else if(locked) bit_number=bit_number+1;
            if(locked) begin
                if(bit_number==0 || bit_number>24) begin
                    if(data_out!==0) $fatal(1,"Philips delay/padding error");
                end else begin
                    word_value={word_value[22:0],data_out};
                    if(bit_number==24) begin
                        if(!ws) left_value=word_value;
                        else begin
                            if({left_value,word_value}!==expected_frame) $fatal(1,"I2S sample mismatch");
                            if(capture && captured<CAPTURE_SAMPLES) begin
                                $fdisplay(csv,"%0d,%0d,%0d",captured,$signed(left_value),$signed(word_value));
                                captured=captured+1;
                            end
                        end
                    end
                end
                if(ws && bit_number==31) checked=checked+1;
            end
        end
    end
    initial begin
        csv=$fopen("sim/live64_results/pcm_live64.csv","w");
        if(!csv) $fatal(1,"open PCM failed");
        $fdisplay(csv,"sample,left,right");
        repeat(5) @(negedge clk); rst_n=1;
        wait(start_ready); @(negedge clk); start=1;
        @(negedge clk); start=0;
        wait(holding); stable_begin=checked;
        // 125 ms after LAST allocated note: longer than A(10)+D(80) ms.
        wait(checked>=stable_begin+6000);
        if(ons!=64 || active_count!=64) $fatal(1,"full load missing");
        steady_underruns=underruns;
        // Check actual per-voice RAM envelope, not just elapsed wall time.
        for(i=0;i<64;i=i+1) begin
            if(dut.u_audio.u_engine.u_state.mem[i][90:88]!=3 ||
               dut.u_audio.u_engine.u_state.mem[i][87:64]!=24'h600000)
                $fatal(1,"voice %0d not at sine sustain",i);
        end
        @(negedge clk); capture=1;
        wait(captured==CAPTURE_SAMPLES); @(negedge clk); capture=0;
        $fclose(csv);
        if(underruns!=steady_underruns || stalls==0) $fatal(1,"continuous output failed");
        stop=1; @(negedge clk); stop=0;
        wait(released); repeat(5) @(negedge clk);
        if(active_count!=0 || ons!=64 || offs!=64 || dones!=64 || busy)
            $fatal(1,"incomplete final release on=%0d off=%0d done=%0d",ons,offs,dones);
        stable_begin=checked; wait(checked>=stable_begin+8);
        if(expected_frame!==0) $fatal(1,"residual dry output");
        meta=$fopen("sim/live64_results/capture_meta.json","w");
        $fdisplay(meta,"{\"sample_rate\":48000,\"samples\":%0d,\"base_note\":36,\"voices\":64,\"velocity\":100,\"timbre\":0,\"gain\":2048,\"bend\":0,\"vibrato\":0,\"fx_enabled\":false,\"warmup_frames\":6000,\"i2s_checked_frames\":%0d,\"steady_underrun_delta\":%0d,\"startup_underruns\":%0d,\"note_ons\":%0d,\"note_offs\":%0d,\"done_events\":%0d}",
            captured,checked,underruns-steady_underruns,steady_underruns,ons,offs,dones);
        $fclose(meta);
        $display("LIVE64 SPECTRUM CAPTURE PASSED samples=%0d i2s_frames=%0d steady_underruns=%0d on=%0d off=%0d done=%0d",captured,checked,underruns-steady_underruns,ons,offs,dones);
        test_passed=1; $finish;
    end
    initial begin #(12.0e9); $fatal(1,"live64 capture timeout"); end
endmodule
