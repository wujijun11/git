`timescale 1ns/1ps
// 顶层集成回归：采集器输出被测试激励替代，独立的MPR/I2C测试仍另行运行。
// 所有事件继续通过原仲裁/FIFO/分配器和64声部引擎，I2S保持实际1024拍/帧。
module tb_menu_system;
    reg clk=0;always #5 clk=~clk;
    reg rn=0;
    tri1 [2:0] scl,sda;
    wire [6:0] active;
    wire [31:0] underruns;
    wire monitor_valid;
    wire main_menu;
    wire [1:0] page,zone,timbre;
    wire signed [6:0] transpose;
    instrument_full_system #(.MENU_DEBOUNCE_CYCLES(3),.MENU_LONG_PRESS_CYCLES(8)) dut(
        .clk(clk),.rst_n(rn),.uart_rx(1'b1),.uart_tx(),.mpr_scl(scl),.mpr_sda(sda),.mpr_irq_n(3'b111),
        .local_action_valid(1'b0),.local_action_ready(),.local_action(8'd0),
        .i2s_bclk(),.i2s_lrclk(),.i2s_data(),.guide_led_data(),.active_count(active),
        .touch_mask(),.guide_mask(),.sensor_ready(),.sensor_fault(),.underrun_count(underruns),
        .overflow_sticky(),.playing(),.recording(),.guide_active(),.video_clk(clk),.video_x(10'd0),
        .video_y(10'd0),.video_de(1'b0),.video_rgb(),.monitor_left(),.monitor_right(),
        .monitor_valid(monitor_valid),.debug_last_note(),.debug_transmit_left(),.debug_audio_reset_status(),
        .menu_main(main_menu),.menu_page(page),.menu_zone(zone),.menu_timbre(timbre),
        .menu_transpose(transpose),.menu_busy(),.menu_error(),.menu_record_count(),
        .menu_prompt_valid(),.menu_prompt_code());
    reg touch=0;reg [11:0] position=0;
    reg inject_valid=0,inject_on=0;
    reg [5:0] inject_source=0;
    reg [6:0] inject_note=40;
    integer outputs=0,prompts=0;
    always @(posedge clk)if(rn)begin
        if(monitor_valid)outputs=outputs+1;
        if(dut.menu_prompt_valid)prompts=prompts+1;
    end
    task cycles(input integer count);repeat(count)@(negedge clk);endtask
    task tap(input integer p);begin position=p;touch=1;cycles(7);touch=0;cycles(20);end endtask
    task event_send(input integer on_value,source,note);
        begin
            @(negedge clk);inject_on=on_value;inject_source=source;inject_note=note;inject_valid=1;
            do @(posedge clk);while(!dut.sensor_er);
            @(negedge clk);inject_valid=0;cycles(3);
        end
    endtask
    integer n,start_outputs;reg [31:0] before_underruns;
    initial begin
        force dut.sensor_ready=3'b111;force dut.sensor_fault=3'b000;
        force dut.slider_active=touch;force dut.slider_position=position;
        force dut.sensor_ev=inject_valid;force dut.sensor_on=inject_on;
        force dut.sensor_source=inject_source;force dut.sensor_note=inject_note;
        force dut.sensor_velocity=7'd96;force dut.sensor_timbre=2'd0;
        cycles(10);rn=1;cycles(30);
        // 四区音色选择，以及App重新设置相同数值时重新取得控制。
        tap(1100);if(timbre!=1 || zone!=1)$fatal(1,"local timbre/highlight missing");
        if(dut.mode_status_payload[39:32]!=1 || dut.mode_status_payload[31:24]!=1 ||
           dut.mode_status_payload[23:16]!=0 || dut.mode_status_payload[0+:8]!=1)
            $fatal(1,"actual timbre/zone not wired into mode return");
        force dut.router_timbre=2'd2;force dut.router_timbre_written=1'b1;cycles(1);
        release dut.router_timbre;release dut.router_timbre_written;cycles(3);
        if(timbre!=2 || zone!=0)$fatal(1,"App timbre did not override local selection");
        touch=1;position=0;cycles(16);touch=0;cycles(20);
        if(!main_menu)$fatal(1,"root missing");
        tap(1100);tap(2800);
        if(page!=1 || transpose!=12 || zone!=3)$fatal(1,"octave page failed");
        if(dut.mode_status_payload[47:40]!=12 || dut.mode_status_payload[23:16]!=1)
            $fatal(1,"actual octave not wired into mode return");
        if(dut.mapping[0 +:7]!=72 || dut.mapping[24*7 +:7]!=96)$fatal(1,"25-key transpose failed");
        tap(2000);if(transpose!=0)$fatal(1,"standard octave failed");
        for(n=0;n<64;n=n+1)event_send(1,n,40+n);
        wait(active==64);start_outputs=outputs;before_underruns=underruns;
        // 64音持续输出期间进入菜单，短音提示也必须按时送入I2S。
        touch=1;position=0;cycles(16);touch=0;cycles(20);tap(100);tap(2800);
        wait(outputs>=start_outputs+5000);
        if(active!=64 || underruns!=before_underruns || prompts<5)
            $fatal(1,"64 voices/menu prompt introduced underrun or voice loss");
        for(n=0;n<64;n=n+1)event_send(0,n,40+n);
        wait(active==0);
        $display("MENU SYSTEM PASS 64 voices, UI prompts, no new underruns, timbre/App priority, transpose and release");$finish;
    end
    initial begin #180000000;$fatal(1,"menu system timeout active=%d outputs=%d",active,outputs);end
endmodule
