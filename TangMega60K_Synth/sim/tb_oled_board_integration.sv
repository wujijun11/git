`timescale 1ns/1ps
// 完整板级顶层+原厂PLL+独立OLED从机。FAST=1仅加速显示/菜单等待；
// FAST=0保留实际100kHz并测外部引脚低/高时间，不把仿真当成实屏验收。
module tb_oled_board_integration #(parameter FAST=1, VOLUME_MODE=0);
    // 高云DDR输出原语使用全局GSR实例，完整HDMI板级仿真必须提供。
    GSR GSR(.GSRI(1'b1));
    reg sys_clk=0;always #10 sys_clk=~sys_clk;
    reg [2:0] key_n=7;
    tri1 [2:0] mpr_scl,mpr_sda;
    tri1 oled_scl,oled_sda;
    wire bc,lr,sd,led;
    reg ack_low=0,nack=0,slide=0;reg [11:0] slide_position=0;
    assign oled_sda=ack_low?1'b0:1'bz;
    board_contest_full_top #(.DEBOUNCE_CYCLES(8),.MENU_HIERARCHY_ENABLE(0),.SLIDER_VOLUME_ENABLE(VOLUME_MODE),.OLED_WAVE_ENABLE(0),
        .OLED_I2C_HZ(FAST?3000000:100000),
        .OLED_POWER_WAIT_CYCLES(8),.OLED_FRAME_WAIT_CYCLES(8)) dut(
        .sys_clk(sys_clk),.key_n(key_n),.mpr_scl(mpr_scl),.mpr_sda(mpr_sda),.mpr_irq_n(3'b111),
        .uart_rx(1'b1),.i2s_bclk(bc),.i2s_lrclk(lr),.i2s_data(sd),.guide_led_data(led),
        .oled_scl(oled_scl),.oled_sda(oled_sda));
    // 加速手势判定，不改变音源、PLL、I2S或事件接口。
    defparam dut.system.MENU_DEBOUNCE_CYCLES=4;
    defparam dut.system.MENU_LONG_PRESS_CYCLES=12;
    integer audio_frames=0,data_count=0,commands=0;
    reg request_menu=0;
    reg [7:0] received[0:2],image[0:1023],font[0:2047];
    integer b,bitno,index,page,column,glyph;
    reg [7:0] expected;
    time fall_time=0,rise_time=0;
    integer checked_low=0,checked_high=0;
    always @(posedge dut.audio_clk)if(dut.rst_n && dut.system.monitor_valid)audio_frames=audio_frames+1;
    always @(negedge oled_scl)begin
        if(!FAST && rise_time!=0)begin
            if($time-rise_time<4000)$fatal(1,"100kHz tHIGH <4us");
            checked_high=checked_high+1;
        end
        fall_time=$time;
    end
    always @(posedge oled_scl)if(dut.rst_n && fall_time!=0)begin
        if(!FAST)begin
            if($time-fall_time<4700)$fatal(1,"100kHz tLOW <4.7us");
            checked_low=checked_low+1;
        end
        rise_time=$time;
    end
    initial forever begin
        @(negedge oled_sda);
        if(oled_scl===1'b1 && dut.rst_n)begin
            for(b=0;b<3;b=b+1)begin
                for(bitno=7;bitno>=0;bitno=bitno-1)begin
                    @(posedge oled_scl);received[b][bitno]=oled_sda;
                end
                @(negedge oled_scl);ack_low=!nack;
                @(posedge oled_scl);@(negedge oled_scl);ack_low=0;
                if(nack)b=3;
            end
            if(!nack)begin
                if(received[0]!==8'h78)$fatal(1,"OLED address is not 0x3C");
                if(received[1]==8'h40)begin
                    if(data_count<1024)image[data_count]=received[2];
                    data_count=data_count+1;
                    if(data_count==10 && FAST)request_menu=1;
                end else if(received[1]==0)begin
                    commands=commands+1;
                    if(commands==1 && received[2]!=8'hae)$fatal(1,"init missing display off");
                    if(commands==25 && received[2]!=8'haf)$fatal(1,"init missing display on");
                end else $fatal(1,"invalid OLED control byte");
            end
        end
    end
    initial begin
        force dut.system.sensor_ready=3'b111;force dut.system.sensor_fault=3'b000;
        force dut.system.slider_active=slide;force dut.system.slider_position=slide_position;
        wait(request_menu);
        @(negedge dut.audio_clk);slide=1;
        repeat(24)@(negedge dut.audio_clk);slide=0;
        repeat(30)@(negedge dut.audio_clk);
        if(!dut.menu_main)$fatal(1,"real slider menu not connected");
    end
    // 独立字符编号参考，验证板上真实menu_*连接，不直接读取渲染器的text或pixels。
    function integer text_glyph(input integer row,input integer col);
        begin
            text_glyph=0;
            case(row)
                0:case(col)0:text_glyph=21;1:text_glyph=22;2:text_glyph=17;3:text_glyph=18;endcase
                1:case(col)0:text_glyph=29;1:text_glyph=30;2:text_glyph=31;3:text_glyph=30;
                    4:text_glyph=32;5:text_glyph=33;6:text_glyph=11;7:text_glyph=12;endcase
                2:case(col)0:text_glyph=57;1:text_glyph=58;2:text_glyph=63;
                    4,5,6,7:text_glyph=1;endcase
                3:case(col)0:text_glyph=50;1:text_glyph=51;2:text_glyph=52;
                    3:text_glyph=53;4:text_glyph=54;5:text_glyph=42;endcase
            endcase
        end
    endfunction
    integer before_audio;
    initial begin
        $readmemh("rtl/audio/rom/menu_font.hex",font);
        wait(dut.rst_n);
        if(!FAST)begin
            wait(data_count>=16);
            if(checked_low<100 || checked_high<100)$fatal(1,"too few timing edges");
            if(dut.OLED_I2C_HZ!=100000 || dut.system.underrun_count!=0)$fatal(1,"default timing/audio error");
            $display("OLED BOARD TIMING PASS actual PLL/audio clock, 100kHz I2C external low/high pulse checks, initialization and data");$finish;
        end
        wait(dut.oled_completed_frames==1);@(negedge dut.audio_clk);
        if(data_count!=1024 || commands!=49 || dut.oled_fault)$fatal(1,"board frame incomplete");
        for(index=0;index<1024;index=index+1)begin
            page=index/128;column=index%128;glyph=text_glyph(page/2,column/16);
            if(VOLUME_MODE)begin
                // 新顶层首帧在音量模式锁存；中途长按进总菜单也不能撕裂该帧。
                glyph=0;
                case(page/2)
                    0:case(column/16)0:glyph=21;1:glyph=13;2:glyph=17;3:glyph=18;endcase
                    1:case(column/16)0:glyph=21;1:glyph=13;3:glyph=2;4,5:glyph=1;6:glyph=14;endcase
                    3:case(column/16)0:glyph=50;1:glyph=51;2:glyph=52;3:glyph=53;
                        4:glyph=19;5:glyph=17;6:glyph=18;endcase
                endcase
                expected=font[glyph*32+(page%2)*16+column%16];
                if(page/2==2)begin
                    if(column==4 || column==123 || (column>=6 && column<=121))
                        expected=(page%2)?8'h07:8'hfc;
                    else if(column==5 || column==122)expected=8'h04;
                    else expected=0;
                end
            end else begin
                expected=font[glyph*32+(page%2)*16+column%16];
                if(page/2==1 && column/32==0)expected=expected^8'hff;
            end
            if(image[index]!==expected)$fatal(1,"board snapshot byte %d got %h expected %h",index,image[index],expected);
        end
        $writememh("sim/audio_results/oled_board_frame.hex",image);
        // 屏幕断开期间由板载KEY0启动实际曲谱，不得阻塞音源和I2S。
        nack=1;wait(dut.oled_fault);
        @(negedge sys_clk);key_n=3'b110;repeat(40)@(negedge sys_clk);key_n=7;
        wait(dut.playing);wait(dut.voices!=0);before_audio=audio_frames;
        repeat(15000)@(negedge dut.audio_clk);
        if(audio_frames<=before_audio+8 || dut.system.underrun_count!=0)$fatal(1,"OLED fault blocked audio");
        nack=0;wait(dut.oled_completed_frames>=2);@(negedge dut.audio_clk);
        if(dut.oled_fault || !dut.menu_main)$fatal(1,"OLED recovery or menu state lost");
        @(negedge sys_clk);key_n=3'b011;repeat(40)@(negedge sys_clk);
        wait(!dut.rst_n);repeat(10)@(negedge dut.audio_clk);
        if(oled_scl!==1 || oled_sda!==1 || dut.oled_completed_frames!=0)$fatal(1,"reset did not release OLED pins");
        $display("OLED BOARD INTEGRATION PASS full top, PLL, menu wiring, 1024-byte snapshot, NACK/audio isolation, recovery and reset");$finish;
    end
    initial begin #800000000;$fatal(1,"OLED board timeout FAST=%d data=%d",FAST,data_count);end
endmodule
