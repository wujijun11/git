`timescale 1ns/1ps
module tb_mono_diagnostic;
    parameter SHORT=0;
    reg clk=0, rst_n=0, start=0, stop=0;
    always #10 clk=~clk;
    wire bclk, ws, data_out, busy, start_ready, active;
    wire [4:0] sequence_index;
    wire [31:0] underruns;
    // Only serialized time is accelerated. DDS, envelope and captured PCM
    // retain their real 48 kHz sample-domain values. The board uses DIV=8.
    mono_diagnostic_core #(.BCLK_HALF_DIV(1), .SINE_ON_FRAMES(SHORT ? 64 : 4096),
        .PIANO_ON_FRAMES(SHORT ? 64 : 4096), .GAP_FRAMES(SHORT ? 100 : 5000),
        .MARKER_FRAMES(SHORT ? 4 : 500)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .stop(stop),
        .i2s_bclk(bclk), .i2s_lrclk(ws), .i2s_data(data_out),
        .busy(busy), .start_ready(start_ready), .active(active),
        .sequence_index(sequence_index), .underruns(underruns));
    // The separate quick protocol run changes only release duration; it writes
    // a separate PCM file and provides no frequency evidence. Full mode keeps
    // the actual 48 kHz attack/decay/release parameters for spectral checks.
    defparam dut.u_engine.RELEASE_MS=SHORT ? 1 : 100;

    // This reference shares the exact same mix/gain operands, retaining the
    // production SHIFT=1. It proves the diagnostic change is 64x, not a pitch
    // or waveform replacement and not export-time normalization.
    wire signed [23:0] baseline_left, baseline_right;
    gain_saturator #(.SHIFT(1)) baseline_gain (
        .clk(clk), .mix_left(dut.u_engine.mix_left),
        .mix_right(dut.u_engine.mix_right), .gain(dut.u_engine.frame_gain),
        .out_left(baseline_left), .out_right(baseline_right));

    function integer expected_note(input integer idx);
        begin
            case(idx)
                0: expected_note=64;
                1: expected_note=65;
                2: expected_note=67;
                3: expected_note=62;
                4: expected_note=60;
                5,6,11,16,17: expected_note=64;
                7,10: expected_note=65;
                8,9: expected_note=67;
                12,15,18,19: expected_note=62;
                default: expected_note=60;
            endcase
        end
    endfunction
    integer note_ons=0, note_offs=0, done_count=0, gain_checks=0;
    integer next_note=0, held_note=0, accepted_samples=0, stalls=0;
    reg note_held=0, stalled=0;
    reg [9:0] stalled_payload;
    always @(posedge clk) begin
        if(!rst_n) begin stalled=0; note_held=0; next_note=0; end
        else begin
            if(underruns!=0) $fatal(1,"Diagnostic I2S underrun");
            if(dut.u_engine.pending_voice!=0 || dut.u_engine.voice_id!=0)
                $fatal(1,"Diagnostic used a voice other than zero");
            if(dut.cmd_valid && !dut.cmd_ready) begin
                stalls=stalls+1;
                if(stalled && stalled_payload!=={dut.cmd_on,dut.cmd_note,dut.cmd_timbre})
                    $fatal(1,"Command changed under backpressure");
                stalled_payload={dut.cmd_on,dut.cmd_note,dut.cmd_timbre}; stalled=1;
            end else stalled=0;
            if(dut.cmd_valid && dut.cmd_ready) begin
                if(dut.cmd_note!=expected_note(sequence_index) ||
                   dut.cmd_timbre!=(sequence_index<5 ? 0 : 2))
                    $fatal(1,"Wrong note or timbre index=%0d",sequence_index);
                if(dut.cmd_on) begin
                    if(note_held || sequence_index!=next_note)
                        $fatal(1,"Overlapping or out-of-order note-on index=%0d expected=%0d",sequence_index,next_note);
                    note_held=1; held_note=dut.cmd_note;
                    next_note=sequence_index==20 ? 0 : sequence_index+1;
                    note_ons=note_ons+1;
                end else begin
                    if(!note_held || dut.cmd_note!=held_note)
                        $fatal(1,"Unpaired note-off");
                    note_held=0; note_offs=note_offs+1;
                end
            end
            if(dut.done_valid && dut.done_ready) begin
                if(dut.done_voice!=0 || note_held) $fatal(1,"Invalid release completion");
                done_count=done_count+1;
            end
            if(dut.sample_valid && dut.sample_ready) begin
                if(dut.sample_left!==($signed(baseline_left)<<<6) ||
                   dut.sample_right!==($signed(baseline_right)<<<6))
                    $fatal(1,"Diagnostic gain is not bit-exact 64x baseline");
                gain_checks=gain_checks+1;
                if(dut.sample_left==24'h7fffff || dut.sample_left==24'h800000 ||
                   dut.sample_right==24'h7fffff || dut.sample_right==24'h800000)
                    $fatal(1,"Diagnostic PCM clipped");
            end
        end
    end

    reg [47:0] expected_queue[0:262143], expected_frame=0;
    integer index_queue[0:262143], stage_queue[0:262143];
    integer written=0, consumed=0, checked=0, nonzero=0;
    integer current_index=0, current_stage=0, capture_run=0;
    integer csv_file;
    reg locked=0, previous_ws=1;
    integer bit_number=0;
    reg [23:0] word_value=0, left_value=0;
    always @(posedge clk) begin
        if(!rst_n) begin written=0; consumed=0; expected_frame=0; end
        else begin
            if(dut.sample_valid && dut.sample_ready) begin
                if(written>=262143) $fatal(1,"Scoreboard capacity exhausted");
                expected_queue[written]={dut.sample_left,dut.sample_right};
                index_queue[written]=sequence_index;
                stage_queue[written]=dut.u_sequence.state;
                written=written+1;
            end
            #0.001;
            if(dut.frame_tick) begin
                if(consumed<written) begin
                    expected_frame=expected_queue[consumed];
                    current_index=index_queue[consumed];
                    current_stage=stage_queue[consumed]; consumed=consumed+1;
                end else begin expected_frame=0; current_stage=0; end
            end
        end
    end
    always @(posedge bclk or negedge rst_n) begin
        if(!rst_n) begin previous_ws=1; locked=0; bit_number=0; word_value=0; left_value=0; end
        else begin
            if(ws!==previous_ws) begin
                if(locked && bit_number!=31) $fatal(1,"Wrong external I2S slot width");
                locked=1; previous_ws=ws; bit_number=0; word_value=0;
            end else if(locked) bit_number=bit_number+1;
            if(locked) begin
                if(bit_number==0 || bit_number>24) begin
                    if(data_out!==0) $fatal(1,"Nonzero Philips I2S delay or padding bit");
                end else begin
                    if(data_out!==0 && data_out!==1) $fatal(1,"Unknown I2S data");
                    word_value={word_value[22:0],data_out};
                    if(bit_number==24) begin
                        if(!ws) left_value=word_value;
                        else begin
                            if({left_value,word_value}!==expected_frame)
                                $fatal(1,"Decoded I2S does not equal accepted PCM frame=%0d",checked);
                            if(expected_frame!=0) nonzero=nonzero+1;
                            if(capture_run==0)
                                $fwrite(csv_file,"%0d,%0d,%0d,%0d,%0d\n",checked,current_index,current_stage,
                                    $signed(left_value),$signed(word_value));
                        end
                    end
                end
                if(ws && bit_number==31) checked=checked+1;
            end
        end
    end

    task automatic await_silence;
        integer before_nonzero, target;
        begin
            wait(start_ready); target=checked+10; wait(checked>=target);
            before_nonzero=nonzero; target=checked+100;
            wait(checked>=target);
            if(nonzero!=before_nonzero || active)
                $fatal(1,"Output did not drain to digital silence");
        end
    endtask
    task automatic start_pulse;
        begin
            wait(start_ready); @(negedge clk); start=1;
            @(negedge clk); start=0;
        end
    endtask
    integer target, prior_ons;
    initial begin
        csv_file=$fopen(SHORT ? "sim/mono_diagnostic_results/protocol-pcm.csv" :
            "sim/mono_diagnostic_results/decoded-pcm.csv","w");
        if(csv_file==0) $fatal(1,"Cannot open PCM evidence file");
        $fwrite(csv_file,"frame,index,stage,left,right\n");
        repeat(5) @(negedge clk); rst_n=1;
        await_silence();
        // Hold the physical start input throughout the complete sequence.
        // Once SEND_ON is presented, stall engine acceptance for 200 cycles.
        @(negedge clk); start=1;
        @(posedge clk); #0.001;
        if(!busy) $fatal(1,"Start was not accepted");
        force dut.u_engine.cmd_ready=1'b0;
        repeat(201) @(negedge clk);
        release dut.u_engine.cmd_ready;
        wait(note_ons==21); wait(!busy); await_silence();
        if(note_offs!=21 || done_count!=21 || stalls<200)
            $fatal(1,"Missing complete sequence or backpressure coverage on=%0d off=%0d done=%0d stalls=%0d",note_ons,note_offs,done_count,stalls);
        prior_ons=note_ons; target=checked+300; wait(checked>=target);
        if(note_ons!=prior_ons || busy) $fatal(1,"Held start automatically replayed");
        capture_run=1; $fclose(csv_file);
        @(negedge clk); start=0; repeat(3) @(negedge clk);
        start_pulse(); wait(note_ons==22); target=checked+(SHORT ? 16 : 200); wait(checked>=target);
        @(negedge clk); stop=1; @(negedge clk); stop=0;
        await_silence();
        if(note_offs!=22 || done_count!=22) $fatal(1,"Stop failed to release note");
        next_note=0; start_pulse(); wait(note_ons==23);
        target=checked+(SHORT ? 16 : 200); wait(checked>=target);
        @(negedge clk); rst_n=0;
        repeat(3) @(negedge clk);
        if(bclk!==0 || data_out!==0 || active || busy || underruns!=0)
            $fatal(1,"Reset failed to clear diagnostic");
        rst_n=1; await_silence();
        if(gain_checks<(SHORT ? 3000 : 190000) || nonzero<(SHORT ? 500 : 50000))
            $fatal(1,"Missing meaningful PCM coverage gain=%0d nonzero=%0d",gain_checks,nonzero);
        $display("MONO DIAGNOSTIC PASSED mode=%0d notes=21 sine=5 piano=16 I2S_frames=%0d nonzero=%0d gain_checks=%0d gain=64x clipped=0 underruns=0 backpressure=%0d on=%0d off=%0d done=%0d stop/restart/reset/held-start",SHORT,checked,nonzero,gain_checks,stalls,note_ons,note_offs,done_count);
        $finish;
    end
    initial begin #1000000000; $fatal(1,"Mono diagnostic timed out"); end
endmodule
