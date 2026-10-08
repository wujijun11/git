`timescale 1ps/1ps
module tb_board_audio_16_48k_i2s;
    reg sys_clk=0;
    always #10000 sys_clk=~sys_clk;
    reg [2:0] key_n=3'b111;
    wire rgb_data,pa_disable,i2s_bclk,i2s_lrclk,i2s_data;
    board_audio_16_48k_i2s_top #(.DEBOUNCE_CYCLES(8)) dut (
        .sys_clk(sys_clk),.key_n(key_n),.rgb_data(rgb_data),
        .pa_disable(pa_disable),.i2s_bclk(i2s_bclk),
        .i2s_lrclk(i2s_lrclk),.i2s_data(i2s_data)
    );
    // Only simulation shortens envelope time. Production retains 10/80/100ms.
    defparam dut.u_audio.u_engine.ATTACK_MS=1;
    defparam dut.u_audio.u_engine.DECAY_MS=1;
    defparam dut.u_audio.u_engine.RELEASE_MS=1;
    integer ons=0,offs=0,slots=0,nonzero_slots=0,clip_slots=0;
    integer on_index=0,off_index=0;
    reg check_hold=0,aligned=0,last_lrclk=1;
    integer bit_index=0;
    reg [23:0] slot_pcm=0;
    time last_bclk=0;
    always @(posedge dut.audio_clk) begin
        if(dut.rst_n) begin
            if(dut.error || dut.full_pulse || dut.done_error_pulse || dut.underruns!=0)
                $fatal(1,"16-voice audio/allocator error");
            if(check_hold && (dut.active_count!=16 || !dut.holding ||
                dut.u_audio.u_captain.u_control.held_mask != 64'hffff))
                $fatal(1,"16 held voices changed during continuous playback");
            if(dut.u_audio.cmd_valid && dut.u_audio.cmd_ready) begin
                if(dut.u_audio.cmd_timbre!=0 || dut.u_audio.cmd_velocity!=100)
                    $fatal(1,"Wrong diagnostic timbre/velocity");
                if(dut.u_audio.cmd_on) begin
                    if(dut.u_audio.cmd_note!=60+on_index)
                        $fatal(1,"Wrong/missing/duplicate note-on");
                    on_index=(on_index+1)%16; ons=ons+1;
                end else begin
                    if(dut.u_audio.cmd_note!=60+off_index)
                        $fatal(1,"Wrong/missing/duplicate note-off");
                    off_index=(off_index+1)%16; offs=offs+1;
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
                    if(slot_pcm!=0) nonzero_slots=nonzero_slots+1;
                    if(slot_pcm==24'h7fffff || slot_pcm==24'h800000) clip_slots=clip_slots+1;
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
    task automatic start_session(input integer expected_ons);
        begin
            keys(3'b110); wait(dut.holding);
            repeat(128) @(negedge dut.audio_clk);
            if(dut.active_count!=16 || ons!=expected_ons || on_index!=0)
                $fatal(1,"Session did not allocate exactly 16 distinct notes");
            keys(3'b111); wait(dut.pressed_sync==0);
        end
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
    integer held_ons,held_nonzero;
    initial begin
        wait(dut.rst_n); silence();
        if(!pa_disable || !dut.pll_locked) $fatal(1,"Board not ready");
        start_session(16);
        // Sustain after releasing KEY0, beyond the shortened attack/decay.
        repeat(196608) @(negedge dut.audio_clk);
        check_hold=1; held_nonzero=nonzero_slots;
        repeat(65536) @(negedge dut.audio_clk);
        if(nonzero_slots<=held_nonzero) $fatal(1,"Continuous hold is silent");
        held_ons=ons; keys(3'b110);
        repeat(16384) @(negedge dut.audio_clk);
        if(ons!=held_ons) $fatal(1,"Busy start retriggered notes");
        check_hold=0; keys(3'b101); wait(dut.released);
        if(offs!=16 || off_index!=0) $fatal(1,"Stop lost note-offs");
        silence(); keys(3'b111); wait(dut.start_ready);
        start_session(32);
        keys(3'b011); wait(!dut.rst_n);
        repeat(4) @(negedge dut.audio_clk);
        if(dut.active_count!=0 || i2s_bclk!==0 || i2s_data!==0)
            $fatal(1,"KEY2 did not immediately clear audio");
        keys(3'b111); wait(dut.rst_n); silence();
        start_session(48);
        force dut.pll_locked=1'b0; wait(!dut.rst_n);
        repeat(4) @(negedge dut.audio_clk);
        if(dut.active_count!=0 || i2s_data!==0) $fatal(1,"PLL loss did not reset audio");
        release dut.pll_locked; wait(dut.rst_n); silence();
        if(clip_slots!=0 || slots<500 || nonzero_slots==0 || dut.underruns!=0)
            $fatal(1,"Final I2S result invalid");
        $display("BOARD 16-VOICE 48K I2S PASSED held=16 on=%0d off=%0d slots=%0d nonzero_slots=%0d clipped=0 underruns=0 start/hold/stop/restart/reset/pll-loss",
                 ons,offs,slots,nonzero_slots);
        $finish;
    end
    initial begin #100000000000; $fatal(1,"16-voice board test timed out"); end
endmodule
