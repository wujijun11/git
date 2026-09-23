`timescale 1ns/1ps
module tb_audio_i2s;
    parameter TIMBRE_OVERRIDE=-1;
    parameter FM=0;
    reg test_passed=0;
    reg clk=0,rst_n=0;
    always #10.1725 clk=~clk; // 1ps quantization of nominal 49.152 MHz
    reg event_valid=0,event_on=0;
    reg [5:0] source=0;
    reg [6:0] note=69,velocity=127;
    reg [1:0] timbre=0;
    wire event_ready;
    reg expr_valid=0;
    wire expr_ready;
    reg [11:0] gain=2048;
    reg signed [12:0] bend=0;
    reg [7:0] depth=0;
    wire bclk,ws,data_out;
    wire [6:0] active_count;
    wire full_pulse,done_error;
    wire [31:0] underruns;
    // Exercise the delay ENABLED in the real 64-voice I2S integration.
    // Exercise the default output format so an accidental default change fails.
    audio_system_v2 #(.FX_ENABLE(1),.FM_ENABLE(FM)) dut (
        .clk(clk),.rst_n(rst_n),.event_valid(event_valid),.event_ready(event_ready),
        .event_on(event_on),.event_source(source),.event_note(note),.event_velocity(velocity),.event_timbre(timbre),
        .expr_valid(expr_valid),.expr_ready(expr_ready),.expr_gain(gain),.expr_bend_cents(bend),.expr_vibrato_cents(depth),
        .i2s_bclk(bclk),.i2s_lrclk(ws),.i2s_data(data_out),.active_count(active_count),
        .full_pulse(full_pulse),.done_error_pulse(done_error),.underrun_count(underruns)
    );
    reg [47:0] expected_queue[0:32767];
    reg [47:0] expected_frame=0;
    integer written=0,consumed=0,checked=0,nonzero=0,stalls=0;
    always @(posedge clk) begin
        if(!rst_n) begin written=0; consumed=0; expected_frame=0; end
        else begin
            if(done_error || full_pulse) $fatal(1,"unexpected allocator error");
            if(dut.sample_valid && !dut.sample_ready) stalls=stalls+1;
            if(dut.sample_valid && dut.sample_ready) begin
                expected_queue[written]={dut.sample_left,dut.sample_right}; written=written+1;
            end
            #0.001;
            if(dut.u_captain.frame_tick) begin
                if(consumed<written) begin expected_frame=expected_queue[consumed]; consumed=consumed+1; end
                else expected_frame=0;
            end
        end
    end
    reg previous_ws=1,locked=0;
    integer bit_number=0;
    reg [23:0] word_value=0,left_value=0;
    always @(posedge bclk or negedge rst_n) begin
        if(!rst_n) begin previous_ws=1; locked=0; bit_number=0; checked=0; word_value=0; left_value=0; end
        else begin
            if(ws!==previous_ws) begin
                if(locked && bit_number!=31) $fatal(1,"I2S slot width");
                locked=1; previous_ws=ws; bit_number=0; word_value=0;
            end else if(locked) bit_number=bit_number+1;
            if(locked) begin
                if(bit_number==0 || bit_number>24) begin
                    if(data_out!==0) $fatal(1,"I2S delay/padding");
                end else begin
                    word_value={word_value[22:0],data_out};
                    if(bit_number==24) begin
                        if(!ws) left_value=word_value;
                        else begin
                            if({left_value,word_value}!==expected_frame) $fatal(1,"PCM/I2S mismatch frame=%0d",checked);
                            if(expected_frame!=0) nonzero=nonzero+1;
                        end
                    end
                end
                if(ws && bit_number==31) checked=checked+1;
            end
        end
    end
    task event_send(input bit on_value,input integer id);
        begin
            @(negedge clk); event_valid=1; event_on=on_value; source=id;
            // 64 actual independent oscillator frequencies (not just 64 slots).
            note=36+id; timbre=TIMBRE_OVERRIDE<0 ? id%2 : TIMBRE_OVERRIDE; velocity=100;
            do @(posedge clk); while(!event_ready);
            @(negedge clk); event_valid=0;
        end
    endtask
    integer i,start_frames;
    reg [31:0] steady_underruns;
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        for(i=0;i<64;i=i+1) event_send(1,i);
        wait(active_count==64); wait(checked>=200);
        steady_underruns=underruns;
        if(steady_underruns!=0) $fatal(1,"startup I2S underrun");
        @(negedge clk); gain=3072; bend=-350; depth=40; expr_valid=1;
        do @(posedge clk); while(!expr_ready);
        @(negedge clk); expr_valid=0;
        wait(checked>=7000);
        if(underruns!=steady_underruns) $fatal(1,"steady-state I2S underrun");
        for(i=0;i<64;i=i+1) event_send(0,i);
        wait(active_count==0); start_frames=checked;
        wait(checked>=start_frames+200);
        if(underruns!=steady_underruns || nonzero<6000 || stalls==0) $fatal(1,"I2S coverage/deadline");
        $display("AUDIO I2S INTEGRATION PASSED voices=64 delay=on frames=%0d nonzero=%0d steady_underrun_delta=0 startup_underruns=%0d stalls=%0d",checked,nonzero,steady_underruns,stalls);
        if(TIMBRE_OVERRIDE==2) $display("PIANO I2S PASSED: 64 piano voices, live gain/bend/vibrato update, release, delay enabled");
        if(TIMBRE_OVERRIDE==3 && FM) $display("FM I2S PASSED: 64 FM voices, live gain/bend/vibrato update, release, delay enabled");
        test_passed=1; $finish;
    end
    initial begin #500000000; $fatal(1,"I2S integration timeout"); end
endmodule
