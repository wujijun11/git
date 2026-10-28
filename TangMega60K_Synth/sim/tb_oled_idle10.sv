`timescale 1ns/1ps
// 1kHz参数时基加速验证10秒策略；真实默认阈值另检查29位计数器边界。
// 不模拟实物供电、PLL掉锁或屏幕发光。
module tb_oled_idle10;
    reg clk=0; always #5 clk=~clk;
    reg rn=0,touch=0,busy=0;
    reg [7:0] error=0;
    reg [11:0] position=0;
    wire main_menu,performance,wave;
    wire [1:0] page,zone;
    slider_menu_controller #(.CLK_HZ(1000),.DEBOUNCE_CYCLES(20),.LONG_PRESS_CYCLES(1000),
        .PERFORMANCE_ENABLE(1),.ROOT_IDLE_CYCLES(0)) menu(
        .clk(clk),.rst_n(rn),.touch_active(touch),.touch_fault(1'b0),.position(position),
        .request_ready(1'b1),.request_valid(),.main_menu(main_menu),.page(page),
        .selected_zone(zone),.action_busy(busy),.performance_mode(performance));
    oled_idle_view #(.IDLE_CYCLES(1000*10)) view(
        .clk(clk),.rst_n(rn),.touch_active(touch),.busy(busy),.error(error),
        .ui_signature({main_menu,page,zone,performance,8'd100}),.waveform_view(wave));
    reg default_touch=1;
    wire default_wave;
    oled_idle_view defaults(.clk(clk),.rst_n(rn),.touch_active(default_touch),
        .busy(1'b0),.error(8'd0),.ui_signature(14'd0),.waveform_view(default_wave));
    task cycles(input integer n); repeat(n) @(negedge clk); endtask
    task gesture(input integer point, duration);
        begin position=point;touch=1;cycles(duration);touch=0;cycles(4);end
    endtask
    task expect_visible_nine_seconds;
        begin
            repeat(9000) begin cycles(1);if(wave)$fatal(1,"UI returned to waveform before nine seconds");end
        end
    endtask
    initial begin
        if(defaults.IDLE_CYCLES!=491520000 || $bits(defaults.idle_count)<29)
            $fatal(1,"49.152MHz default is not ten seconds or counter width is insufficient");
        cycles(4);rn=1;cycles(4);
        // 数值边界：旧28位计数器无法容纳491520000；默认端点不能溢出。
        default_touch=0;cycles(2);
        force defaults.idle_count=29'd491519998;
        cycles(1);release defaults.idle_count;
        cycles(1);if(default_wave)$fatal(1,"default threshold fired one cycle early");
        cycles(1);if(!default_wave)$fatal(1,"default threshold did not fire");
        default_touch=1;
        gesture(0,1200);
        if(!main_menu || performance || wave)$fatal(1,"root entry did not restart idle time");
        expect_visible_nine_seconds();
        cycles(1100);
        if(!wave || !main_menu)$fatal(1,"root did not show waveform with menu state retained");
        gesture(2000,50);
        if(main_menu || page!=2 || wave)$fatal(1,"first wake gesture lost submenu selection");
        expect_visible_nine_seconds();cycles(1100);
        if(!wave || page!=2)$fatal(1,"submenu idle did not preserve page");
        gesture(0,1200);
        expect_visible_nine_seconds();
        // 10秒以前再次触摸：应完整重计，不能沿用上一次即将到期的计数。
        position=1000;touch=1;cycles(12000);
        if(wave)$fatal(1,"finger held on slider but UI timed out");
        touch=0;cycles(4);
        if(page!=1 || main_menu)$fatal(1,"release did not select transpose page");
        expect_visible_nine_seconds();cycles(1100);
        if(!wave || page!=1)$fatal(1,"retouch did not restart full timeout");
        busy=1;cycles(3);if(wave)$fatal(1,"busy state hidden");
        busy=0;error=1;cycles(11000);if(wave)$fatal(1,"error state hidden");
        error=0;cycles(4);expect_visible_nine_seconds();cycles(1100);
        if(!wave)$fatal(1,"normal idle did not resume after error");
        $display("OLED IDLE10 PASS ten-second threshold, 29-bit boundary, root/submenu restart, held touch and priority");
        $finish;
    end
    initial begin #2000000;$fatal(1,"idle10 test timeout");end
endmodule
