`timescale 1ns/1ps
// 音量/总菜单/子页面手势。小计数加速等待，保留边界与反压语义。
module tb_slider_performance;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,touch_active=0,touch_fault=0,request_ready=1,action_busy=0;
    reg [11:0] position=0;
    wire request_valid,main_menu,performance_mode,volume_position_valid;
    wire [11:0] volume_position;
    wire [1:0] request_kind,request_page,request_zone,page,selected_zone,preview_zone;
    slider_menu_controller #(.CLK_HZ(1000),.DEBOUNCE_CYCLES(3),
        .LONG_PRESS_CYCLES(8),.ROOT_IDLE_CYCLES(30),.PERFORMANCE_ENABLE(1),
        .HYSTERESIS(12)) dut(.*);
    wire expr_valid;
    wire [11:0] expr_gain;
    slider_volume_control volume(.clk(clk),.rst_n(rst_n),.position_valid(volume_position_valid),
        .position(volume_position),.expr_valid(expr_valid),.expr_ready(1'b1),.expr_gain(expr_gain));
    integer requests=0,gains=0,last_gain=2048;
    reg stalled=0;
    reg [5:0] saved;
    always @(posedge clk)if(rst_n)begin
        if(stalled && (!request_valid || {request_kind,request_page,request_zone}!==saved))
            $fatal(1,"Menu request changed under backpressure");
        stalled<=request_valid && !request_ready;
        saved<={request_kind,request_page,request_zone};
        if(request_valid && request_ready)requests=requests+1;
        if(expr_valid)begin gains=gains+1;last_gain=expr_gain;end
    end else stalled<=0;
    task cycles(input integer count);repeat(count)@(negedge clk);endtask
    task tap(input integer value);
        begin position=value;touch_active=1;cycles(7);touch_active=0;cycles(8);end
    endtask
    task long_press(input integer value);
        begin position=value;touch_active=1;cycles(16);end
    endtask
    task release_touch;
        begin touch_active=0;cycles(8);end
    endtask
    integer before_gains,before_requests;
    initial begin
        cycles(3);rst_n=1;cycles(3);
        if(!performance_mode || main_menu || gains)$fatal(1,"Default volume mode missing");
        tap(1536);if(last_gain<1024 || last_gain>1025 || requests)$fatal(1,"Volume tap made a menu action");
        before_gains=gains;long_press(0);
        if(performance_mode || !main_menu || gains!=before_gains)$fatal(1,"Left menu hold altered volume");
        release_touch();
        action_busy=1;cycles(60);
        if(!main_menu || performance_mode)$fatal(1,"Busy root timed out");
        action_busy=0;cycles(29);
        if(!main_menu)$fatal(1,"Root returned before idle limit");
        cycles(2);if(!performance_mode || main_menu)$fatal(1,"Root idle did not return");
        long_press(0);release_touch();tap(1100);
        if(main_menu || performance_mode || page!=1)$fatal(1,"Could not enter octave page");
        cycles(100);if(performance_mode || main_menu)$fatal(1,"Subpage wrongly timed out");
        before_gains=gains;tap(2800);
        if(page!=1 || performance_mode || gains!=before_gains)$fatal(1,"Subpage tap altered gain");
        before_requests=requests;long_press(2800);
        if(!performance_mode || main_menu)$fatal(1,"Right long press did not return volume");
        cycles(25);if(gains!=before_gains)$fatal(1,"Return hold became full volume");
        release_touch();if(requests!=before_requests+1 || gains!=before_gains)$fatal(1,"Return release triggered another action");
        // 从中间起始可拖到0并保持，不被左端菜单长按误判。
        position=1536;touch_active=1;cycles(7);position=0;cycles(20);
        if(!performance_mode || last_gain!=0)$fatal(1,"Dragging to zero opened menu or failed mute");
        release_touch();
        before_gains=gains;touch_active=1;position=0;cycles(7);touch_fault=1;cycles(2);
        touch_active=0;cycles(8);touch_fault=0;cycles(4);
        if(gains!=before_gains)$fatal(1,"Fault became a low-volume release");
        // 请求被反压时不能超时丢弃或叠加返回动作。
        request_ready=0;long_press(0);release_touch();cycles(50);
        if(!request_valid || !main_menu || performance_mode)$fatal(1,"Pending root request timed out");
        request_ready=1;cycles(5);tap(2000);
        if(page!=2 || performance_mode)$fatal(1,"Recording page missing");
        cycles(50);if(performance_mode)$fatal(1,"Recording page timed out");
        long_press(0);release_touch();if(!main_menu)$fatal(1,"Subpage left hold did not return root");
        rst_n=0;cycles(3);rst_n=1;cycles(3);
        if(!performance_mode || main_menu || request_valid)$fatal(1,"Reset did not restore volume mode");
        $display("SLIDER PERFORMANCE PASS volume, root-only timeout, persistent subpages, left/right holds, fault, backpressure, reset");
        $finish;
    end
    initial begin #100000;$fatal(1,"Performance gestures timeout");end
endmodule
