`timescale 1ns/1ps
module tb_board_audio;
    reg clk=0;
    always #10 clk=~clk;
    reg [2:0] keys=7;
    wire rgb,mute;
    board_audio_diagnostic_top #(.DEBOUNCE_CYCLES(8)) dut
        (.sys_clk(clk),.key_n(keys),.rgb_data(rgb),.pa_disable(mute));
    integer frame_count=0, edge_count=0;
    time previous_frame=0;
    always @(posedge dut.bclk) if(dut.rst_n) edge_count=edge_count+1;
    always @(negedge dut.lrclk) if(dut.rst_n) begin
        if(previous_frame!=0 && $time-previous_frame!=20480)
            $fatal(1,"I2S frame period wrong");
        previous_frame=$time; frame_count=frame_count+1;
    end
    reg [47:0] expected_queue[0:15];
    reg [47:0] expected_frame=0;
    integer written=0, consumed=0, checked=0;
    always @(posedge clk) begin
        if (!dut.rst_n) begin written=0; consumed=0; expected_frame=0; end
        else begin
            if (dut.u_live64.u_audio.sample_valid && dut.u_live64.u_audio.sample_ready) begin
                if (written-consumed>=16) $fatal(1,"scoreboard overflow");
                expected_queue[written%16]={dut.u_live64.u_audio.sample_left,dut.u_live64.u_audio.sample_right};
                written=written+1;
            end
            #0.001;
            if (dut.u_live64.u_audio.u_captain.frame_tick) begin
                if (consumed<written) begin expected_frame=expected_queue[consumed%16]; consumed=consumed+1; end
                else expected_frame=0;
            end
        end
    end
    reg previous_ws=1,locked=0;
    integer bit_number=0;
    reg [23:0] word_value=0,left_value=0;
    // Independent receiver: reconstruct signed PCM from the actual Philips I2S pins.
    always @(posedge dut.bclk or negedge dut.rst_n) begin
        if(!dut.rst_n) begin previous_ws=1; locked=0; bit_number=0; checked=0; word_value=0; left_value=0; end
        else begin
            if(dut.lrclk!==previous_ws) begin
                if(locked && bit_number!=31) $fatal(1,"not 32-bit I2S slots");
                locked=1; previous_ws=dut.lrclk; bit_number=0; word_value=0;
            end else if(locked) bit_number=bit_number+1;
            if(locked) begin
                if(bit_number==0 || bit_number>24) begin
                    if(dut.serial_data!==0) $fatal(1,"Philips delay/padding error");
                end else begin
                    word_value={word_value[22:0],dut.serial_data};
                    if(bit_number==24) begin
                        if(!dut.lrclk) left_value=word_value;
                        else begin
                            if ({left_value,word_value} !== expected_frame)
                                $fatal(1,"I2S PCM mismatch");
                        end
                    end
                end
                if(dut.lrclk && bit_number==31) checked=checked+1;
            end
        end
    end
    initial begin
        wait(dut.board_ready); repeat(100) @(negedge clk);
        keys=6; wait(dut.holding); repeat(150000) @(negedge clk);
        if(dut.active_count!=64 || !dut.serial_seen || dut.fault || !mute || frame_count<100 || checked<100 || dut.underruns!=1)
            $fatal(1,"64 voice board integration failed active=%d seen=%b fault=%b mute=%b frames=%d underruns=%d error=%b",dut.active_count,dut.serial_seen,dut.fault,mute,frame_count,dut.underruns,dut.error);
        keys=7; repeat(20) @(negedge clk);
        keys=5; wait(!dut.busy); repeat(20) @(negedge clk);
        if(dut.active_count!=0 || dut.fault) $fatal(1,"Release failed");
        keys=7; repeat(20) @(negedge clk); keys=6; wait(dut.holding);
        keys=3; wait(!dut.rst_n); previous_frame=0;
        repeat(20) @(negedge clk);
        if(dut.active_count!=0) $fatal(1,"Reset failed");
        keys=7; repeat(100) @(negedge clk);
        if(!dut.rst_n || dut.busy || dut.fault) $fatal(1,"Reset recovery failed");
        $display("BOARD AUDIO INTEGRATION PASSED frames=%0d",frame_count); $finish;
    end
    initial begin #1000000000; $fatal(1,"Timeout"); end
endmodule
