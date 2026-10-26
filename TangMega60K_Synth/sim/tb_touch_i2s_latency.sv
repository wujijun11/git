`timescale 1ns/1ps
// 完整OLED板级顶层：三组MPR121串行从机→事件→64声部引擎→外部I2S解码。
// 起点是已滤波触摸寄存器变更，不含真实MPR模拟检测、DAC和喇叭。
// 只缩短冷启动校准等待；steady-state轮询、400kHz总线、ADSR与I2S不加速。
module tb_touch_i2s_latency;
    GSR GSR(.GSRI(1'b1));
    reg sys_clk=0;
    always #10 sys_clk=~sys_clk;
    reg [2:0] key_n=3'b111, irq_n=3'b111;
    tri1 [2:0] scl, sda;
    tri1 oled_scl, oled_sda;
    wire bc,lr,sd;
    board_contest_full_top dut(
        .sys_clk(sys_clk),.key_n(key_n),.mpr_scl(scl),.mpr_sda(sda),.mpr_irq_n(irq_n),
        .uart_rx(1'b1),.i2s_bclk(bc),.i2s_lrclk(lr),.i2s_data(sd),
        .oled_scl(oled_scl),.oled_sda(oled_sda));
    // 1ms初始稳定等待仍大于0.5ms常态轮询，不会改变ready后的SETTLE分支。
    defparam dut.system.sensors.sensors[0].sampler.RESET_CYCLES=8;
    defparam dut.system.sensors.sensors[1].sampler.RESET_CYCLES=8;
    defparam dut.system.sensors.sensors[2].sampler.RESET_CYCLES=8;
    defparam dut.system.sensors.sensors[0].sampler.SETTLE_CYCLES=49152;
    defparam dut.system.sensors.sensors[1].sampler.SETTLE_CYCLES=49152;
    defparam dut.system.sensors.sensors[2].sampler.SETTLE_CYCLES=49152;
    defparam dut.system.sensors.sensors[0].sampler.CALIBRATION_SNAPSHOTS=1;
    defparam dut.system.sensors.sensors[1].sampler.CALIBRATION_SNAPSHOTS=1;
    defparam dut.system.sensors.sensors[2].sampler.CALIBRATION_SNAPSHOTS=1;
    mpr121_bus_model m0(dut.audio_clk,scl[0],sda[0],2'd0,1'b0,1'b0,1'b0);
    mpr121_bus_model m1(dut.audio_clk,scl[1],sda[1],2'd0,1'b0,1'b0,1'b0);
    mpr121_bus_model m2(dut.audio_clk,scl[2],sda[2],2'd0,1'b0,1'b0,1'b0);

    integer case_id=0, events_on=0, events_off=0, commands_on=0, commands_off=0;
    reg measuring=0;
    reg [24:0] expected_mask=0, seen_events=0, seen_commands=0;
    time changed_at=0, first_event_at=0, last_event_at=0;
    time first_command_at=0,last_command_at=0,first_i2s_at=0,first_snapshot_at=0;
    integer source_index;
    integer pcm_frames=0, slots=0;
    always @(posedge dut.audio_clk) if(dut.rst_n) begin
        if(dut.system.underrun_count!=0 || dut.overflow || dut.sensor_fault!=0)
            $fatal(1,"touch latency audio/sensor error");
        if(dut.system.monitor_valid) pcm_frames=pcm_frames+1;
        if(measuring) begin
            if(first_snapshot_at==0 &&
                ((dut.system.sensors.snap_valid[0] && dut.system.sensors.snap_ready[0] && dut.system.sensors.snaps[7:0]!=0) ||
                 (dut.system.sensors.snap_valid[1] && dut.system.sensors.snap_ready[1] && dut.system.sensors.snaps[351:344]!=0) ||
                 (dut.system.sensors.snap_valid[2] && dut.system.sensors.snap_ready[2] && dut.system.sensors.snaps[696:688]!=0)))
                first_snapshot_at=$time;
            if(dut.system.sensor_ev && dut.system.sensor_er) begin
                source_index=dut.system.sensor_source-25;
                if(source_index<0 || source_index>=25) $fatal(1,"bad touch source");
                if(dut.system.sensor_on) begin
                    if(!expected_mask[source_index] || seen_events[source_index]) $fatal(1,"unexpected/duplicate touch");
                    seen_events[source_index]=1;
                    events_on=events_on+1;
                    if(first_event_at==0) first_event_at=$time;
                    last_event_at=$time;
                end else events_off=events_off+1;
            end
            if(dut.system.cmdv && dut.system.cmdr) begin
                if(dut.system.tone!==2) $fatal(1,"production piano timbre changed");
                if(dut.system.cmdon) begin
                    source_index=dut.system.note-60;
                    if(source_index<0 || source_index>=25 || !expected_mask[source_index] || seen_commands[source_index])
                        $fatal(1,"unexpected/duplicate engine command note=%d",dut.system.note);
                    seen_commands[source_index]=1;
                    commands_on=commands_on+1;
                    if(first_command_at==0) first_command_at=$time;
                    last_command_at=$time;
                end else commands_off=commands_off+1;
            end
        end
    end
    // 标准Philips I2S：WS翻转位是延迟位，随后24位有效，再7位填零。
    reg last_lr=1,aligned=0;
    integer bit_number=0;
    reg [23:0] serial_sample=0;
    always @(posedge bc or negedge dut.system.audio_rst_n) begin
        if(!dut.system.audio_rst_n) begin
            last_lr=1; aligned=0; bit_number=0; serial_sample=0;
        end else begin
            if(lr!=last_lr) begin
                if(aligned && bit_number!=31) $fatal(1,"I2S slot length changed");
                last_lr=lr; aligned=1; bit_number=0; serial_sample=0;
            end else if(aligned) bit_number=bit_number+1;
            if(aligned) begin
                if(sd!==1'b0 && sd!==1'b1) $fatal(1,"I2S unknown bit");
                if((bit_number==0 || bit_number>24) && sd!==0) $fatal(1,"I2S delay/padding error");
                if(bit_number>=1 && bit_number<=24) serial_sample={serial_sample[22:0],sd};
                if(bit_number==24) begin
                    slots=slots+1;
                    if(measuring && serial_sample!=0 && first_i2s_at==0) first_i2s_at=$time;
                end
            end
        end
    end

    task set_touches(input [24:0] mask);
        begin
            m0.set_touches({4'd0,mask[7:0]});
            m1.set_touches({4'd0,mask[15:8]});
            m2.set_touches({3'd0,mask[24:16]});
        end
    endtask
    task await_ready;
        begin
            wait(dut.rst_n && dut.sensor_ready==7);
            repeat(2000) @(negedge dut.audio_clk);
            if(dut.system.sensors.POLL_CYCLES!=24576 || dut.system.sensors.I2C_HZ!=400000 ||
                dut.system.synth.VOICE_COUNT!=64 || dut.system.synth.ATTACK_MS!=10 ||
                dut.system.audio.BCLK_HALF_DIV!=8)
                $fatal(1,"steady-state production timing parameters overridden");
        end
    endtask
    task cold_reset;
        begin
            measuring=0;
            set_touches(0);
            irq_n=7;
            @(negedge sys_clk); key_n=3'b011;
            wait(!dut.rst_n);
            repeat(100) @(negedge sys_clk);
            key_n=3'b111;
            await_ready();
        end
    endtask
    integer output_file,frames_before,wait_cycles;
    time release_at;
    task run_case(input integer id,input [24:0] mask,input integer phase,input bit with_irq);
        begin
            case_id=id;
            // 相位0：刚冻结旧快照；相位1：空闲轮询初段；相位2：快照末字节。
            if(phase==0) wait(m0.state==2 && m0.ptr==0 && m0.txbit==7);
            else if(phase==1) wait(dut.system.sensors.sensors[1].sampler.state==5 &&
                dut.system.sensors.sensors[1].sampler.timer==100);
            else wait(m2.state==2 && m2.ptr==42 && m2.txbit==3);
            @(negedge dut.audio_clk);
            expected_mask=mask; seen_events=0; seen_commands=0;
            events_on=0; events_off=0; commands_on=0; commands_off=0;
            first_snapshot_at=0; first_event_at=0;last_event_at=0;
            first_command_at=0;last_command_at=0;first_i2s_at=0;
            changed_at=$time; measuring=1;
            set_touches(mask);
            irq_n=with_irq ? 3'b000:3'b111;
            wait_cycles=0;
            while((seen_commands!=mask || first_i2s_at==0) && wait_cycles<245760) begin
                @(negedge dut.audio_clk);wait_cycles=wait_cycles+1;
            end
            if(seen_events!=mask || seen_commands!=mask || first_i2s_at==0 ||
                first_i2s_at<first_command_at || first_command_at<first_event_at ||
                first_event_at<first_snapshot_at || first_snapshot_at<changed_at)
                $fatal(1,"touch latency ordering/5ms response failed case=%d seen=%h/%h",id,seen_events,seen_commands);
            if(first_i2s_at-changed_at>5000000 || last_command_at-changed_at>5000000)
                $fatal(1,"touch digital latency >5ms");
            $fdisplay(output_file,"%0d,%0d,%0d,%0d,%0t,%0t,%0t,%0t,%0t,%0t,%0t",id,phase,with_irq,
                commands_on,changed_at,first_snapshot_at,first_event_at,last_event_at,first_command_at,last_command_at,first_i2s_at);
            $display("TOUCH I2S LATENCY case=%0d phase=%0d irq=%0d keys=%0d snapshot=%.3fus event=%.3fus command=%.3fus last_command=%.3fus complete_I2S=%.3fus",
                id,phase,with_irq,commands_on,(first_snapshot_at-changed_at)/1000.0,
                (first_event_at-changed_at)/1000.0,(first_command_at-changed_at)/1000.0,
                (last_command_at-changed_at)/1000.0,(first_i2s_at-changed_at)/1000.0);
            // 松开也必须经实际串行读取产生相同数量的NoteOff；保持尾音而非强清声部。
            @(negedge dut.audio_clk);set_touches(0);irq_n=0;release_at=$time;
            while(commands_off<commands_on && $time-release_at<5000000) @(negedge dut.audio_clk);
            if(commands_off!=commands_on || events_off!=events_on) $fatal(1,"touch release lost");
            frames_before=pcm_frames;
            repeat(4096) @(negedge dut.audio_clk);
            if(pcm_frames<=frames_before+2 || dut.system.underrun_count!=0)
                $fatal(1,"audio did not continue after release");
            measuring=0;
        end
    endtask
    initial begin
        $timeformat(-9,0,"",0);
        output_file=$fopen("sim/audio_results/touch_i2s_latency.csv","w");
        if(output_file==0) $fatal(1,"cannot write touch latency report");
        $fdisplay(output_file,"case_id,phase,irq,key_count,status_ns,snapshot_ns,first_event_ns,last_event_ns,first_command_ns,last_command_ns,first_nonzero_i2s_ns");
        await_ready();
        run_case(0,25'h000001,0,1);
        cold_reset();run_case(1,25'h000100,1,0);
        cold_reset();run_case(2,25'h1000000,2,1);
        cold_reset();run_case(3,25'h1ffffff,0,0);
        $fclose(output_file);
        $display("TOUCH I2S LATENCY PASS 4 phase/bus cases, 25-note chord, serial I2C, note releases, 24/32 I2S, no underrun; excludes physical sensor filtering/DAC");
        $finish;
    end
    initial begin #150000000;$fatal(1,"touch latency full-board timeout case=%d",case_id);end
endmodule
