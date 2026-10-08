`timescale 1ps/1ps
module tb_board_sequence16_48k_i2s;
    reg sys_clk=0;
    always #10000 sys_clk=~sys_clk;
    reg [2:0] key_n=3'b111;
    wire rgb_data,pa_disable,i2s_bclk,i2s_lrclk,i2s_data;
    // Only simulation accelerates sequence counters and envelopes. The real
    // 49.152MHz audio clock and complete external I2S path remain unchanged.
    board_sequence16_48k_i2s_top #(.DEBOUNCE_CYCLES(8),
        .SEQ_CLK_HZ(4915200),.NOTE_MS(1),.GAP_MS(1)) dut (
        .sys_clk(sys_clk),.key_n(key_n),.rgb_data(rgb_data),
        .pa_disable(pa_disable),.i2s_bclk(i2s_bclk),
        .i2s_lrclk(i2s_lrclk),.i2s_data(i2s_data)
    );
    defparam dut.u_audio.u_engine.ATTACK_MS=0;
    defparam dut.u_audio.u_engine.DECAY_MS=0;
    defparam dut.u_audio.u_engine.RELEASE_MS=0;
    integer ons=0,offs=0,slots=0,nonzero_slots=0,quiet_slots=0;
    integer expected_note=60,current_note=60,max_voices=0,quiet_cycles=0;
    integer tone_slots[0:15];
    integer i,prior_ons,prior_nonzero;
    reg aligned=0,last_lrclk=1;
    integer bit_index=0;
    reg [23:0] slot_pcm=0;
    time last_bclk=0;
    always @(negedge dut.rst_n) begin
        expected_note=60; current_note=60; quiet_cycles=0;
    end
    always @(posedge dut.audio_clk) begin
        if(dut.rst_n) begin
            if(dut.error || dut.full_pulse || dut.done_error_pulse || dut.underruns!=0)
                $fatal(1,"Sequential audio/allocator error");
            if(dut.active_count>max_voices) max_voices=dut.active_count;
            if(dut.active_count>1) $fatal(1,"Sequential notes overlapped");
            if(dut.active_count==0) quiet_cycles=quiet_cycles+1;
            else quiet_cycles=0;
            if(dut.u_audio.cmd_valid && dut.u_audio.cmd_ready) begin
                if(dut.u_audio.cmd_timbre!=0 || dut.u_audio.cmd_velocity!=100)
                    $fatal(1,"Wrong sequential timbre/velocity");
                if(dut.u_audio.cmd_on) begin
                    if(dut.u_audio.cmd_note!=expected_note || ons!=offs)
                        $fatal(1,"Wrong sequence order or unpaired prior note");
                    current_note=expected_note;
                    expected_note=(expected_note==75) ? 60 : expected_note+1;
                    ons=ons+1;
                end else begin
                    if(dut.u_audio.cmd_note!=current_note || ons!=offs+1)
                        $fatal(1,"Wrong sequential note-off");
                    offs=offs+1;
                end
            end
        end
    end
    always @(posedge i2s_bclk or negedge dut.rst_n) begin
        if(!dut.rst_n) begin
            aligned=0; last_lrclk=1; bit_index=0; slot_pcm=0; last_bclk=0;
        end else begin
            if(last_bclk!=0 && ($time-last_bclk<325500 || $time-last_bclk>325600))
                $fatal(1,"Wrong external BCLK period");
            last_bclk=$time;
            if(i2s_lrclk!=last_lrclk) begin
                if(aligned) begin
                    if(bit_index!=31) $fatal(1,"Wrong external I2S slot width");
                    slots=slots+1;
                    if(slot_pcm==24'h7fffff || slot_pcm==24'h800000)
                        $fatal(1,"Sequential PCM clipped");
                    if(slot_pcm!=0) begin
                        nonzero_slots=nonzero_slots+1;
                        tone_slots[current_note-60]=tone_slots[current_note-60]+1;
                    end
                    if(quiet_cycles>3072) begin
                        quiet_slots=quiet_slots+1;
                        if(slot_pcm!=0) $fatal(1,"Inter-note gap is not digital silence");
                    end
                end
                aligned=1; bit_index=0; slot_pcm=0; last_lrclk=i2s_lrclk;
            end else if(aligned) bit_index=bit_index+1;
            if(aligned) begin
                if(i2s_data!==1'b0 && i2s_data!==1'b1)
                    $fatal(1,"Unknown external I2S data");
                if((bit_index==0 || bit_index>24) && i2s_data!==0)
                    $fatal(1,"Nonzero Philips I2S delay/padding bit");
                if(bit_index>=1 && bit_index<=24) slot_pcm={slot_pcm[22:0],i2s_data};
            end
        end
    end
    task automatic keys(input [2:0] value);
        @(negedge sys_clk); key_n=value;
    endtask
    task automatic silence;
        integer slots_before;
        begin
            repeat(4096) @(negedge dut.audio_clk);
            slots_before=nonzero_slots;
            repeat(4096) @(negedge dut.audio_clk);
            if(dut.active_count!=0 || nonzero_slots!=slots_before)
                $fatal(1,"I2S failed to drain to digital silence");
        end
    endtask
    initial begin
        for(i=0;i<16;i=i+1) tone_slots[i]=0;
        wait(dut.rst_n); silence();
        if(!pa_disable || !dut.pll_locked) $fatal(1,"Board not ready");
        keys(3'b110); wait(dut.holding); keys(3'b111);
        wait(ons>=18); wait(dut.holding);
        for(i=0;i<16;i=i+1)
            if(tone_slots[i]==0) $fatal(1,"Note %0d never reached external I2S",60+i);
        if(quiet_slots<16 || max_voices!=1) $fatal(1,"Missing single-note/silence evidence");
        keys(3'b101); wait(dut.released); silence();
        if(ons!=offs) $fatal(1,"KEY1 left a held note");
        prior_ons=ons; keys(3'b111); wait(dut.start_ready);
        expected_note=60; keys(3'b110); wait(dut.holding); keys(3'b111);
        if(ons!=prior_ons+1 || current_note!=60) $fatal(1,"Restart did not begin at C4");
        prior_nonzero=nonzero_slots;
        // Two queued stereo pairs plus the current frame can precede the new
        // voice. Observe enough exported frames instead of just allocation.
        repeat(8192) @(negedge dut.audio_clk);
        if(nonzero_slots<=prior_nonzero) $fatal(1,"Restart remained silent");
        keys(3'b011); wait(!dut.rst_n);
        repeat(4) @(negedge dut.audio_clk);
        if(dut.active_count!=0 || i2s_bclk!==0 || i2s_data!==0)
            $fatal(1,"KEY2 did not clear sequential audio");
        keys(3'b111); wait(dut.rst_n); silence();
        if(slots<300 || nonzero_slots==0 || dut.underruns!=0)
            $fatal(1,"Final sequential I2S result invalid");
        $display("BOARD SEQUENCE16 48K I2S PASSED notes=16 wrap=1 max_voices=%0d on=%0d off=%0d slots=%0d nonzero_slots=%0d quiet_slots=%0d clipped=0 underruns=0 start/stop/restart/reset",
            max_voices,ons,offs,slots,nonzero_slots,quiet_slots);
        $finish;
    end
    initial begin #100000000000; $fatal(1,"Sequence16 board test timed out"); end
endmodule
