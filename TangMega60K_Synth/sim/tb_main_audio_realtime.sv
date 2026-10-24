`timescale 1ns/1ps
// Isolated reproduction of the production voice_engine -> runtime dry FX ->
// I2S path at 1024 audio clocks/frame. This does not model placed FPGA timing.
module tb_main_audio_realtime;
    parameter N=64;
    parameter HOLD_FRAMES=4096;
    parameter RELEASE_FRAMES=6000;
    parameter PROBE_FRAMES=0;
    reg test_passed=0;
    reg clk=0,rst_n=0;
    always #10.1725 clk=~clk;
    reg cmd_valid=0,cmd_on=0;
    reg [6:0] cmd_note=60;
    wire cmd_ready,done_valid,engine_valid,engine_ready,fx_valid,fx_ready;
    wire [5:0] done_voice;
    wire signed [23:0] engine_l,engine_r,fx_l,fx_r;
    wire sample_begin,bclk,ws,dout,frame_tick;
    wire [31:0] underruns;
    voice_engine #(.VOICE_COUNT(N),.FM_ENABLE(1),.FX_ENABLE(0),.AUTO_HEADROOM(1)) engine(
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
        .cmd_on(cmd_on),.cmd_voice(6'd0),.cmd_note(cmd_note),
        .cmd_velocity(7'd100),.cmd_timbre(2'd2),
        .done_valid(done_valid),.done_ready(1'b1),.done_voice(done_voice),
        .sample_valid(engine_valid),.sample_ready(engine_ready),
        .sample_left(engine_l),.sample_right(engine_r),
        .engine_sample_begin(sample_begin),.active_gain(12'd2048),
        .active_bend_cents(13'sd0),.active_vibrato_cents(8'd0));
    runtime_audio_fx effects(.clk(clk),.rst_n(rst_n),.mode(2'd0),
        .in_valid(engine_valid),.in_ready(engine_ready),.in_left(engine_l),.in_right(engine_r),
        .out_valid(fx_valid),.out_ready(fx_ready),.out_left(fx_l),.out_right(fx_r));
    i2s_tx #(.BCLK_HALF_DIV(8)) sink(.clk(clk),.rst_n(rst_n),
        .sample_valid(fx_valid),.sample_ready(fx_ready),.sample_left(fx_l),.sample_right(fx_r),
        .i2s_bclk(bclk),.i2s_lrclk(ws),.i2s_data(dout),.frame_tick(frame_tick),
        .fifo_level(),.underrun_pulse(),.underrun_sticky(),.underrun_count(underruns));
    integer cycles=0,begun_cycle=-1,computed=0,min_compute=999999,max_compute=0;
    integer min_first_valid=999999,max_first_valid=0;
    reg first_valid_seen=0;
    integer frames=0,last_frame=-1,done_count=0,engine_w=0,fx_w=0,pop_r=0;
    integer capture=0,captured=0,fd=0,stats=0,phase=0,current_note=0;
    reg [47:0] engine_queue[0:32767],fx_queue[0:32767];
    reg [47:0] expected_frame=0;
    reg [47:0] prev_engine=0,prev_fx=0;
    reg engine_stall=0,fx_stall=0;
    integer stalls=0;
    always @(posedge clk) begin
        if(rst_n) begin
            cycles=cycles+1;
            if(sample_begin) begin begun_cycle=cycles; first_valid_seen=0; end
            if(engine_valid && !first_valid_seen && begun_cycle>=0) begin
                first_valid_seen=1;
                if(cycles-begun_cycle<min_first_valid) min_first_valid=cycles-begun_cycle;
                if(cycles-begun_cycle>max_first_valid) max_first_valid=cycles-begun_cycle;
            end
            if(engine_stall && (!engine_valid || {engine_l,engine_r}!==prev_engine))
                $fatal(1,"engine changed under backpressure");
            if(fx_stall && (!fx_valid || {fx_l,fx_r}!==prev_fx))
                $fatal(1,"runtime FX changed under backpressure");
            engine_stall=engine_valid&&!engine_ready;
            fx_stall=fx_valid&&!fx_ready;
            prev_engine={engine_l,engine_r}; prev_fx={fx_l,fx_r};
            if(engine_stall || fx_stall) stalls=stalls+1;
            if(engine_valid && engine_ready) begin
                if((^{engine_l,engine_r})===1'bx) $fatal(1,"unknown engine PCM");
                engine_queue[engine_w]={engine_l,engine_r}; engine_w=engine_w+1;
                if(begun_cycle<0) $fatal(1,"output without frame begin");
                if(cycles-begun_cycle<min_compute) min_compute=cycles-begun_cycle;
                if(cycles-begun_cycle>max_compute) max_compute=cycles-begun_cycle;
                if(cycles-begun_cycle>1024) $fatal(1,"audio compute exceeded frame deadline");
                computed=computed+1; begun_cycle=-1;
            end
            if(fx_valid && fx_ready) begin
                if(fx_w>=engine_w || {fx_l,fx_r}!==engine_queue[fx_w])
                    $fatal(1,"dry runtime FX changed or reordered PCM");
                fx_queue[fx_w]={fx_l,fx_r}; fx_w=fx_w+1;
            end
            if(done_valid) done_count=done_count+1;
            #0.001;
            if(frame_tick) begin
                if(last_frame>=0 && cycles-last_frame!=1024) $fatal(1,"frame period mismatch");
                last_frame=cycles;
                if(pop_r<fx_w) begin expected_frame=fx_queue[pop_r]; pop_r=pop_r+1; end
                else expected_frame=0;
            end
        end
    end
    reg previous_ws=1,locked=0;
    integer bit_number=0;
    reg [23:0] word_value=0,left_value=0;
    always @(posedge bclk) begin
        if(rst_n) begin
            if(ws!==previous_ws) begin
                if(locked && bit_number!=31) $fatal(1,"I2S slot width");
                locked=1; previous_ws=ws; bit_number=0; word_value=0;
            end else if(locked) bit_number=bit_number+1;
            if(locked) begin
                if(bit_number==0 || bit_number>24) begin
                    if(dout!==0) $fatal(1,"I2S delay/padding");
                end else begin
                    word_value={word_value[22:0],dout};
                    if(bit_number==24) begin
                        if(!ws) left_value=word_value;
                        else begin
                            if({left_value,word_value}!==expected_frame) $fatal(1,"serialized I2S PCM mismatch");
                            if(capture) begin
                                $fdisplay(fd,"%0d,%0d,%0d,%0d",captured,phase,$signed(left_value),$signed(word_value));
                                captured=captured+1;
                            end
                        end
                    end
                end
                if(ws && bit_number==31) begin
                    frames=frames+1;
                    if(frames==16 || frames%4096==0)
                        $display("REALTIME PROGRESS N=%0d frames=%0d first_valid=%0d..%0d accept_latency=%0d..%0d underruns=%0d",N,frames,min_first_valid,max_first_valid,min_compute,max_compute,underruns);
                end
            end
        end
    end
    task wait_frames(input integer count);
        integer target;
        begin target=frames+count; wait(frames>=target); @(negedge clk); end
    endtask
    task command(input bit on_value,input integer midi);
        begin
            @(negedge clk); cmd_valid=1; cmd_on=on_value; cmd_note=midi;
            do @(posedge clk); while(!cmd_ready);
            @(negedge clk); cmd_valid=0;
        end
    endtask
    task run_note(input integer midi);
        integer old_done;
        begin
            current_note=midi; captured=0; phase=1; old_done=done_count;
            fd=$fopen($sformatf("pcm/n%0d_note_%0d.csv",N,midi),"w");
            if(!fd) $fatal(1,"cannot open PCM output");
            $fdisplay(fd,"sample,phase,left,right"); capture=1;
            command(1,midi); wait_frames(HOLD_FRAMES);
            phase=2; command(0,midi); wait_frames(RELEASE_FRAMES);
            capture=0; $fclose(fd);
            if(done_count!=old_done+1) $fatal(1,"voice release was not acknowledged");
            if(expected_frame!==0) $fatal(1,"release tail is not silent");
            if(underruns!=0) $fatal(1,"I2S underrun");
            $display("REALTIME NOTE PASS N=%0d midi=%0d frames=%0d compute=%0d..%0d underruns=%0d",N,midi,captured,min_compute,max_compute,underruns);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk); rst_n=1; wait_frames(16);
        run_note(60); run_note(84);
        stats=$fopen($sformatf("pcm/n%0d_stats.csv",N),"w");
        $fdisplay(stats,"voices,frames,computed,min_accept_latency,max_accept_latency,min_first_valid,max_first_valid,underruns,done_count,stalls");
        $fdisplay(stats,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",N,frames,computed,min_compute,max_compute,min_first_valid,max_first_valid,underruns,done_count,stalls);
        $fclose(stats);
        test_passed=1; $display("MAIN REALTIME AUDIO PASS N=%0d",N); $finish;
    end
    initial begin #1000000000; $fatal(1,"realtime audio test timeout"); end
    initial begin
        if(PROBE_FRAMES>0) begin
            wait(frames>=PROBE_FRAMES);
            $display("REALTIME SHORT PROBE N=%0d frames=%0d first_valid=%0d..%0d accept_latency=%0d..%0d underruns=%0d",N,frames,min_first_valid,max_first_valid,min_compute,max_compute,underruns);
            if(underruns!=0) $fatal(1,"probe underrun");
            test_passed=1; $finish;
        end
    end
endmodule
