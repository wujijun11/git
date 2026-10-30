`timescale 1ns/1ps
// 真实滑条计算、菜单、64声部音源和UART；仅在MPR采样快照边界注入数字数据。
// 强制快照不能覆盖实物电气/供电故障，不把本测试称为修复了核心板熄灯。
module tb_sustain_system #(parameter FULL_LOAD=0);
    localparam HIERARCHY=1;
    reg clk=0;always #5 clk=~clk;
    reg rn=0,rx=1;
    tri1 [2:0] scl,sda;
    wire tx,playing,recording,guide,monitor;
    wire [6:0] voices;
    wire [31:0] underruns;
    instrument_full_system #(.SUSTAIN_ENABLE(1),.STABLE_CHORD_MIX_ENABLE(1),.SLIDER_VOLUME_ENABLE(1),.MENU_DEBOUNCE_CYCLES(64),
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
    integer sustain_responses=0;
    reg [79:0] sustain_payload=0;
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
                if(packet[4]==8'h86)begin
                    for(integer k=0;k<10;k=k+1)sustain_payload[k*8+:8]=packet[5+k];
                    sustain_responses=sustain_responses+1;
                end
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

    integer engine_ons=0,engine_offs=0,nonzero=0;
    always @(posedge clk)if(rn)begin
        if(dut.engine_cmd_valid && dut.engine_cmd_ready)begin
            if(dut.engine_cmd_on)engine_ons=engine_ons+1;
            else engine_offs=engine_offs+1;
        end
        if(monitor && dut.monitor_left!=0)nonzero=nonzero+1;
    end
    task request(input [7:0] op,input [79:0] payload,input integer expected);
        integer before_ack,timeout;reg [7:0] c,item;
        begin
            before_ack=acks;c=crc(crc(crc(0,1),seq),op);
            send_byte(8'ha5);send_byte(8'h5a);send_byte(1);send_byte(seq);send_byte(op);
            for(integer k=0;k<10;k=k+1)begin item=payload[k*8+:8];send_byte(item);c=crc(c,item);end
            send_byte(c);timeout=0;
            while(acks==before_ack && timeout<30000)begin cycles(1);timeout=timeout+1;end
            if(acks!=before_ack+1 || ack_status!=expected || ack_seq!=seq)$fatal(1,"sustain ACK failure op=%0d",op);
            seq=seq+1'b1;cycles(3200);
        end
    endtask
    task pedal_query;
        integer before_count;
        begin
            before_count=sustain_responses;request(8,80'd5,0);
            if(sustain_responses!=before_count+1 || sustain_payload[7:0]!=1 ||
               sustain_payload[15:8]!=dut.sustain_enabled || sustain_payload[23:16]!=dut.sustain_deferred_count ||
               sustain_payload[31:24]!=64 || sustain_payload[79:32]!=0)$fatal(1,"sustain status snapshot mismatch");
        end
    endtask
    task frame_wait(input integer count);
        integer target;
        begin target=outputs+count;while(outputs<target)cycles(1);end
    endtask
    integer before_pcm,f;
    initial begin
        cycles(8);rn=1;cycles(5000);snapshot(-1);pedal_query();
        if(dut.sustain_enabled)$fatal(1,"pedal must default off");
        if(FULL_LOAD)begin
            request(3,80'h0102,0);
            for(integer n=0;n<64;n=n+1)request(1,(80'd1<<32)|(80'd2<<24)|(80'd100<<16)|((80'd36+n)<<8),0);
            if(voices!=64)$fatal(1,"full64 note-on missing");
            for(integer n=0;n<64;n=n+1)request(1,(80'd2<<24)|(80'd100<<16)|((80'd36+n)<<8),0);
            if(dut.sustain_deferred_count!=64 || engine_offs!=0)$fatal(1,"full64 sustain missing");
            before_pcm=nonzero;frame_wait(512);
            if(nonzero==before_pcm || dut.synth.frame_active_count!=64)$fatal(1,"full64 output missing");
            request(3,80'h0002,0);frame_wait(6000);
            if(voices || dut.sustain_deferred_count || engine_offs!=64 || underruns)$fatal(1,"full64 release/continuity failed");
            $display("SUSTAIN SYSTEM FULL64 PASS PCM=%0d ons=%0d offs=%0d",outputs,engine_ons,engine_offs);
            $finish;
        end

        // 板上真实滑条快照->新菜单->延音开关；不强制内部踏板寄存器。
        hierarchical_root();tap(0);tap(3);
        if(dut.menu_view!=9)$fatal(1,"sustain menu missing");
        tap(1);cycles(100);
        if(!dut.sustain_enabled || !dut.menu_waveform_view)$fatal(1,"menu pedal on failed");
        pedal_query();request(3,80'h0202,1); // CONFIG target2,value2非法。
        if(!dut.sustain_enabled)$fatal(1,"invalid setting changed pedal");
        request(2,80'h080001,0); // 只把总增益设回Q1.11 unity，不改变弯音/颤音。
        key_mask=1;snapshot(-1);cycles(5000);key_mask=0;snapshot(-1);cycles(5000);
        if(voices!=1 || dut.sustain_deferred_count!=1 || engine_offs!=0)$fatal(1,"key release not sustained");
        frame_wait(6000);before_pcm=nonzero;frame_wait(128);
        if(voices!=1 || nonzero==before_pcm)$fatal(1,"sustain not audible beyond ordinary release");
        // 同一实体键重弹，仍经原分配器，新旧两个独立声部同时保留。
        key_mask=1;snapshot(-1);cycles(5000);key_mask=0;snapshot(-1);cycles(5000);
        if(voices!=2 || dut.sustain_deferred_count!=2)$fatal(1,"same-key re-strike ownership");
        // 第二个实体键保持不放，关闭延音只能释放前面两个已松开的声部。
        key_mask=2;snapshot(-1);cycles(5000);request(3,80'h0002,0);pedal_query();
        frame_wait(6000);
        if(voices!=1 || dut.sustain_deferred_count!=0 || engine_offs!=2)$fatal(1,"pedal-up killed held key or leaked tail");
        key_mask=0;snapshot(-1);frame_wait(6000);
        if(voices!=0)$fatal(1,"last released key did not recycle");
        // 全部停止会清除开关和全部声部；语义沿用原PANIC。
        request(3,80'h0102,0);key_mask=4;snapshot(-1);cycles(5000);key_mask=0;snapshot(-1);
        request(4,80'd5,0);cycles(10000);pedal_query();
        if(voices || dut.sustain_enabled || dut.sustain_deferred_count)$fatal(1,"panic retained sustain state");
        // 模拟现有断连看门狗进入释放阶段，只验证数字逻辑，不冒充真实射频断连。
        request(3,80'h0102,0);force dut.phone_releasing=1;cycles(4);release dut.phone_releasing;cycles(4);
        if(dut.sustain_enabled)$fatal(1,"watchdog release retained pedal");
        if(underruns!=0)$fatal(1,"audio underrun during sustain integration");
        $display("SUSTAIN SYSTEM PASS voices=%0d PCM=%0d ons=%0d offs=%0d queries=%0d",voices,outputs,engine_ons,engine_offs,sustain_responses);
        $finish;
    end
    initial begin #800000000;$fatal(1,"sustain system timeout");end
endmodule
