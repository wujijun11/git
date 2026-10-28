`timescale 1ns/1ps
// 真实滑条计算、菜单、64声部音源和UART；仅在MPR采样快照边界注入数字数据。
// 强制快照不能覆盖实物电气/供电故障，不把本测试称为修复了核心板熄灯。
module tb_slider_liveness #(parameter HIERARCHY=0);
    reg clk=0;always #5 clk=~clk;
    reg rn=0,rx=1;
    tri1 [2:0] scl,sda;
    wire tx,playing,recording,guide,monitor;
    wire [6:0] voices;
    wire [31:0] underruns;
    instrument_full_system #(.SLIDER_VOLUME_ENABLE(1),.MENU_DEBOUNCE_CYCLES(64),
        .HIERARCHICAL_MENU_ENABLE(HIERARCHY),.MENU_WAVE_IDLE_CYCLES(1000000),
        .MENU_LONG_PRESS_CYCLES(128),.MENU_ROOT_IDLE_CYCLES(0),.UART_BAUD(3072000)) dut(
        .clk(clk),.rst_n(rn),.uart_rx(rx),.uart_tx(tx),.mpr_scl(scl),.mpr_sda(sda),.mpr_irq_n(3'b111),
        .local_action_valid(1'b0),.local_action(8'd0),.active_count(voices),
        .underrun_count(underruns),.playing(playing),.recording(recording),.guide_active(guide),
        .video_clk(clk),.video_x(10'd0),.video_y(10'd0),.video_de(1'b0),.monitor_valid(monitor));
    reg [1031:0] samples=0;
    reg [2:0] sample_valid=0, sensor_bad=0;
    reg [7:0] key_mask=0;
    integer outputs=0,snapshots=0;
    always @(posedge clk)if(rn && monitor)outputs=outputs+1;
    initial begin
        force dut.sensors.snaps=samples;
        force dut.sensors.snap_valid=sample_valid;
        force dut.sensors.ready=3'b111;
        force dut.sensors.fault=sensor_bad;
    end
    task cycles(input integer n);repeat(n)@(negedge clk);endtask
    task snapshot(input integer slider_zone);
        integer n,timeout;
        begin
            @(negedge clk);samples=0;samples[7:0]=key_mask;
            // baseline=100对应400，未触摸filtered=400；触摸电极filtered=320。
            for(n=0;n<4;n=n+1)begin
                samples[(38+n)*8+:8]=100;
                samples[(20+n*2)*8+:16]=(n==slider_zone)?320:400;
            end
            if(slider_zone>=0)samples[8+slider_zone]=1;
            sample_valid=1;timeout=0;
            do begin @(posedge clk);timeout=timeout+1;end while(!dut.sensors.snap_ready[0] && timeout<2000);
            if(timeout>=2000)$fatal(1,"MPR snapshot input blocked");
            @(negedge clk);sample_valid=0;snapshots=snapshots+1;cycles(64);
        end
    endtask
    task tap(input integer zone);
        begin snapshot(zone);cycles(96);snapshot(-1);cycles(200);end
    endtask
    task hold(input integer zone);
        begin snapshot(zone);cycles(512);snapshot(-1);cycles(200);end
    endtask
    task hierarchical_root;
        begin
            if(dut.menu_waveform_view)tap(2); // 唤醒手势只调音量，不选中子动作。
            hold(0);
            if(dut.menu_view!=1)$fatal(1,"hierarchical root entry failed");
        end
    endtask
    function [7:0] crc(input [7:0] old,input [7:0] byte_value);
        reg [7:0] c;
        begin c=old^byte_value;for(integer k=0;k<8;k=k+1)c=c[7]?(c<<1)^7:c<<1;crc=c;end
    endfunction
    task send_byte(input [7:0] value);
        begin rx=0;cycles(16);for(integer k=0;k<8;k=k+1)begin rx=value[k];cycles(16);end rx=1;cycles(16);end
    endtask
    wire [7:0] byte_rx;wire byte_valid,frame_error;
    remote_uart_rx #(.CLK_HZ(49152000),.BAUD(3072000)) receiver(
        .clk(clk),.reset(!rn),.rx(tx),.data(byte_rx),.valid(byte_valid),.framing_error(frame_error));
    reg [7:0] packet[0:15];integer byte_index=0,acks=0;
    reg [7:0] ack_seq=0,ack_status=0,check;
    always @(posedge clk)if(rn)begin
        if(frame_error)$fatal(1,"UART response framing error");
        if(byte_valid)begin
            packet[byte_index]=byte_rx;
            if(byte_index==15)begin
                check=0;for(integer k=2;k<15;k=k+1)check=crc(check,packet[k]);
                if(packet[0]!=8'ha5 || packet[1]!=8'h5a || packet[2]!=1 || check!=byte_rx)
                    $fatal(1,"UART response packet/CRC error");
                if(packet[4]==8'h80)begin acks=acks+1;ack_seq=packet[3];ack_status=packet[6];end
                byte_index=0;
            end else byte_index=byte_index+1;
        end
    end else byte_index=0;
    reg [7:0] seq=0;
    task status_query;
        integer before_ack,timeout;reg [7:0] c;
        begin
            before_ack=acks;c=crc(crc(crc(0,1),seq),8);
            send_byte(8'ha5);send_byte(8'h5a);send_byte(1);send_byte(seq);send_byte(8);
            for(integer k=0;k<10;k=k+1)begin send_byte(0);c=crc(c,0);end
            send_byte(c);timeout=0;
            while(acks==before_ack && timeout<20000)begin cycles(1);timeout=timeout+1;end
            if(acks!=before_ack+1 || ack_seq!=seq || ack_status!=0)
                $fatal(1,"UART status handshake stalled after slider activity");
            seq=seq+1'b1;cycles(3000);
        end
    endtask
    task configure_effect(input integer value);
        integer before_ack,timeout;reg [7:0] c,item;
        begin
            before_ack=acks;c=crc(crc(crc(0,1),seq),3);
            send_byte(8'ha5);send_byte(8'h5a);send_byte(1);send_byte(seq);send_byte(3);
            for(integer k=0;k<10;k=k+1)begin
                item=k==0?1:k==1?value:0;send_byte(item);c=crc(c,item);
            end
            send_byte(c);timeout=0;
            while(acks==before_ack && timeout<30000)begin cycles(1);timeout=timeout+1;end
            if(acks!=before_ack+1 || ack_status!=0 || ack_seq!=seq)$fatal(1,"effect configuration ACK missing");
            seq=seq+1'b1;cycles(1000);
            if(dut.fx!=value)$fatal(1,"phone effect did not override local selection");
        end
    endtask
    integer n,before_outputs,timeout,before_gain;
    initial begin
        cycles(8);rn=1;cycles(5000);snapshot(-1);status_query();
        key_mask=1;snapshot(1);cycles(3000);
        before_outputs=outputs;
        // 连续滑过左端不应误开菜单；持续音不应因增益为0误判成系统死机。
        for(n=0;n<100;n=n+1)begin
            snapshot(n%4);cycles(160);
            if(n%10==0)status_query();
        end
        snapshot(-1);cycles(1000);
        if(!dut.menu_volume_mode || voices==0 || outputs<=before_outputs || underruns!=0)
            $fatal(1,"continuous slider affected engine liveness");
        if(HIERARCHY)begin
            hierarchical_root();tap(0);tap(0);tap(1);
            if(dut.timbre!=1 || !dut.menu_waveform_view)$fatal(1,"nested timbre selection failed");
            tap(1);cycles(6000);
            before_gain=dut.gain;
            hierarchical_root();tap(1);tap(1);
            snapshot(3);cycles(60000);
            if(dut.bend!=200 || dut.gain!=before_gain || dut.menu_control_value!=200 || dut.menu_control_negative)
                $fatal(1,"real bend path/readback changed volume");
            snapshot(-1);cycles(60000);
            if(dut.bend!=0 || dut.synth.u_expression.bend_smooth!=0)$fatal(1,"bend did not settle after release");
            hierarchical_root();tap(1);tap(2);snapshot(3);cycles(60000);
            if(dut.vibrato!=100 || dut.gain!=before_gain || dut.menu_control_percent!=100)
                $fatal(1,"real vibrato path/readback changed volume");
            snapshot(-1);hierarchical_root();tap(1);tap(3);cycles(60000);
            if(dut.vibrato!=0 || dut.bend!=0 || dut.gain!=before_gain)$fatal(1,"expression reset changed gain");
            hierarchical_root();tap(0);tap(2);tap(1);cycles(5000);
            if(dut.fx!=1 || !dut.menu_waveform_view)$fatal(1,"local audio effect selection failed");
            configure_effect(0);configure_effect(3);
            status_query();hierarchical_root();tap(2);
        end else begin hold(0);tap(2);end
        if(dut.menu_main || dut.menu_page!=2)$fatal(1,"record menu entry failed");
        tap(0);if(!recording)$fatal(1,"record start failed");
        key_mask=2;snapshot(-1);key_mask=0;snapshot(-1);status_query();
        if(HIERARCHY)begin hierarchical_root();tap(2);end
        tap(1);if(recording)$fatal(1,"record stop failed");
        if(HIERARCHY)begin hierarchical_root();tap(2);end
        tap(2);cycles(4000);status_query(); // 回放与查询共存。
        if(HIERARCHY)begin hierarchical_root();tap(2);end
        tap(3);timeout=0;
        while(dut.panic_discard && timeout<20000)begin cycles(1);timeout=timeout+1;end
        if(dut.panic_discard)$fatal(1,"menu PANIC did not drain");
        status_query();
        // 采样故障中止手势，恢复后仍能查询及演奏。
        snapshot(0);sensor_bad=1;cycles(500);snapshot(-1);sensor_bad=0;cycles(1000);status_query();
        if(HIERARCHY)begin
            hierarchical_root();tap(3);tap(3);cycles(5000);
            if(!dut.performance.learn_active)$fatal(1,"score learning action missing");
            status_query();
        end
        hold(3);tap(3);key_mask=1;snapshot(-1);cycles(4000);status_query();
        if(!dut.audio_rst_n || underruns!=0 || dut.crc_errors || dut.framing_errors || dut.uart_overflows)
            $fatal(1,"reset/transport/audio did not recover");
        if(acks<15 || snapshots<110)$fatal(1,"insufficient stress coverage");
        if(HIERARCHY)$display("HIERARCHY SYSTEM PASS snapshots=%0d UART_ACKs=%0d PCM_frames=%0d real expressions, nested menus, record/replay, learning, effects, PANIC and fault",snapshots,acks,outputs);
        else $display("SLIDER LIVENESS PASS snapshots=%0d UART_ACKs=%0d PCM_frames=%0d continuous slide, menu, record, replay, PANIC and sensor fault",snapshots,acks,outputs);
        $finish;
    end
    initial begin #20000000;$fatal(1,"slider liveness timeout");end
endmodule
