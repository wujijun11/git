`timescale 1ns/1ps
// 新模式实际接入完整64声部引擎；UART发送独立表情，触摸在采集器输出边界注入。
module tb_slider_volume_system;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,rx=1,touch=0;
    reg [11:0] position=0;
    tri1 [2:0] scl,sda;
    wire [6:0] voices;
    wire performance_mode,main_menu,recording,playing,guide;
    wire [7:0] volume_percent;
    wire [1:0] page;
    wire [31:0] underruns;
    wire monitor_valid;
    instrument_full_system #(.SLIDER_VOLUME_ENABLE(1),.MENU_DEBOUNCE_CYCLES(3),
        .MENU_LONG_PRESS_CYCLES(8),.MENU_ROOT_IDLE_CYCLES(60),.UART_BAUD(3072000)) dut(
        .clk(clk),.rst_n(rst_n),.uart_rx(rx),.mpr_scl(scl),.mpr_sda(sda),.mpr_irq_n(3'b111),
        .local_action_valid(1'b0),.local_action(8'd0),.active_count(voices),
        .underrun_count(underruns),.recording(recording),.playing(playing),.guide_active(guide),
        .video_clk(clk),.video_x(10'd0),.video_y(10'd0),.video_de(1'b0),
        .monitor_valid(monitor_valid),.menu_main(main_menu),.menu_page(page),
        .menu_volume_mode(performance_mode),.menu_volume_percent(volume_percent));
    reg inject_valid=0,inject_on=0;
    reg [5:0] inject_source=0;
    reg [6:0] inject_note=0;
    integer outputs=0,applied=0;
    reg checking=0;
    integer last_smooth=2048,difference;
    always @(posedge clk)if(rst_n)begin
        if(monitor_valid)outputs=outputs+1;
        if(dut.control.expr_applied)applied=applied+1;
        // 平滑只能在生成采样帧时推进；每帧gain变化不超过原GAIN_STEP=8。
        if(checking && dut.synth.state==16)begin
            difference=dut.synth.frame_gain-last_smooth;
            if(difference< -8 || difference>8)$fatal(1,"Gain smoothing jumped %0d",difference);
            last_smooth=dut.synth.frame_gain;
        end
    end
    task cycles(input integer n);repeat(n)@(negedge clk);endtask
    task tap(input integer p);begin position=p;touch=1;cycles(7);touch=0;cycles(12);end endtask
    task hold(input integer p);begin position=p;touch=1;cycles(16);touch=0;cycles(12);end endtask
    function [7:0] crc(input [7:0] old,input [7:0] b);
        reg [7:0] q;
        begin q=old^b;for(integer k=0;k<8;k=k+1)q=q[7]?(q<<1)^7:q<<1;crc=q;end
    endfunction
    task send_byte(input [7:0] b);
        begin rx=0;repeat(16)@(negedge clk);
            for(integer k=0;k<8;k=k+1)begin rx=b[k];repeat(16)@(negedge clk);end
            rx=1;repeat(16)@(negedge clk);
        end
    endtask
    reg [7:0] seq=0;
    task expression(input [2:0] mask,input [11:0] gain,input signed [12:0] bend,input [7:0] vibrato);
        reg [79:0] payload;
        reg [7:0] c;
        begin
            payload=0;payload[2:0]=mask;payload[19:8]=gain;
            payload[39:24]={{3{bend[12]}},bend};payload[47:40]=vibrato;
            c=crc(crc(crc(0,1),seq),2);
            @(negedge clk);send_byte(8'ha5);send_byte(8'h5a);send_byte(1);send_byte(seq);send_byte(2);
            for(integer k=0;k<10;k=k+1)begin send_byte(payload[k*8+:8]);c=crc(c,payload[k*8+:8]);end
            send_byte(c);seq=seq+1'b1;cycles(6000);
        end
    endtask
    task event_send(input bit on_value,input integer source,note);
        begin
            @(negedge clk);inject_on=on_value;inject_source=source;inject_note=note;inject_valid=1;
            do @(posedge clk);while(!dut.sensor_er);
            @(negedge clk);inject_valid=0;cycles(2);
        end
    endtask
    task wait_gain(input integer value);
        integer timeout;
        begin
            timeout=0;
            while(dut.gain!=value && timeout<10000)begin cycles(1);timeout=timeout+1;end
            if(dut.gain!=value)$fatal(1,"Gain target timeout expected=%0d actual=%0d",value,dut.gain);
        end
    endtask
    integer n,before_outputs;
    initial begin
        force dut.sensor_ready=3'b111;force dut.sensor_fault=3'b000;
        force dut.slider_active=touch;force dut.slider_position=position;
        force dut.sensor_ev=inject_valid;force dut.sensor_on=inject_on;
        force dut.sensor_source=inject_source;force dut.sensor_note=inject_note;
        force dut.sensor_velocity=7'd90;force dut.sensor_timbre=2'd2;
        cycles(6);rst_n=1;cycles(4000);checking=1;
        if(!performance_mode || dut.gain!=2048)$fatal(1,"Default volume integration");
        expression(3'b110,2048,13'sd120,8'd24);
        if(dut.bend!=120 || dut.vibrato!=24)$fatal(1,"UART expression did not apply");
        tap(1536);wait_gain(1025);
        if(dut.bend!=120 || dut.vibrato!=24)$fatal(1,"Slider overwrote bend/vibrato");
        expression(3'b001,12'd512,0,0);wait_gain(512);
        if(dut.bend!=120 || dut.vibrato!=24)$fatal(1,"App gain overwrote unmasked expression");
        tap(1536);wait_gain(1025);
        // 菜单长按不改音量。录制页不超时，离开页面也不停止录制。
        hold(0);tap(2000);tap(0);cycles(100);
        if(page!=2 || performance_mode || !recording || dut.gain!=1025)$fatal(1,"Recording submenu/volume isolation");
        hold(2800);cycles(100);
        if(!performance_mode || !recording)$fatal(1,"Return stopped recording");
        event_send(1,25,60);event_send(0,25,60);
        cycles(300);
        if(dut.record_count<2)$fatal(1,"Recording stopped outside page");
        hold(0);tap(2000);tap(1100);cycles(100);
        if(recording)$fatal(1,"Stop recording failed");
        hold(2800);
        // 回总菜单再自动返回不应影响播放；同时证明未按键不自动更改音量。
        hold(0);tap(2800);tap(0);cycles(200);
        if(!playing)$fatal(1,"Score playback missing");
        hold(0);cycles(100);
        if(!performance_mode || !playing || dut.gain!=1025)$fatal(1,"Root timeout stopped playback or changed volume");
        // 停旧曲谱后64个不同来源全满，音量连续变化仍按时供数。
        hold(0);tap(2800);tap(1100);cycles(2000);hold(2800);
        wait(voices==0);
        for(n=0;n<64;n=n+1)event_send(1,n,40+n);
        wait(voices==64);before_outputs=outputs;
        position=1536;touch=1;cycles(7);
        repeat(8)begin position=3072;cycles(1200);position=384;cycles(1200);end
        touch=0;cycles(1200);
        wait(outputs>=before_outputs+100);
        if(voices!=64 || underruns!=0)$fatal(1,"Volume created voice loss/underrun");
        for(n=0;n<64;n=n+1)event_send(0,n,40+n);
        wait(voices==0);
        if(dut.crc_errors || dut.framing_errors || dut.uart_overflows)$fatal(1,"UART transport errors");
        if(applied<5)$fatal(1,"Insufficient frame-boundary expression updates");
        $display("SLIDER VOLUME SYSTEM PASS actual UART, mask isolation, last writer, frame smoothing, persistent record/play, 64 voices, release, no underrun");
        $finish;
    end
    initial begin #100000000;$fatal(1,"Volume integration timeout voices=%0d gain=%0d",voices,dut.gain);end
endmodule
