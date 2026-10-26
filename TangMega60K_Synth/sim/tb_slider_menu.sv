`timescale 1ns/1ps
module tb_slider_menu;
    reg clk=0; always #5 clk=~clk;
    reg rn=0,touch=0,ready=1,fault=0;
    reg [11:0] position=1536;
    wire valid,main_menu;
    wire [1:0] kind,request_page,zone,page,selected,preview;
    slider_menu_controller #(.CLK_HZ(1000),.DEBOUNCE_CYCLES(3),
        .LONG_PRESS_CYCLES(8),.HYSTERESIS(12)) dut(
        .clk(clk),.rst_n(rn),.touch_active(touch),.touch_fault(fault),.position(position),
        .request_valid(valid),.request_ready(ready),.request_kind(kind),
        .request_page(request_page),.request_zone(zone),.main_menu(main_menu),
        .page(page),.selected_zone(selected),.preview_zone(preview));
    integer count=0;
    reg [5:0] events[0:31];
    reg stalled=0;
    reg [5:0] previous;
    always @(posedge clk) if(rn) begin
        if(stalled && (!valid || {kind,request_page,zone}!==previous))
            $fatal(1,"menu request changed under backpressure");
        stalled<=valid&&!ready;
        previous<={kind,request_page,zone};
        if(valid&&ready) begin events[count]={kind,request_page,zone};count=count+1;end
    end else stalled<=0;
    task cycles(input integer n);repeat(n)@(negedge clk);endtask
    task tap(input integer p);
        begin @(negedge clk);position=p;touch=1;cycles(6);touch=0;cycles(3);end
    endtask
    task expect_event(input integer n,input [1:0] k,p,z);
        begin
            if(count!=n || events[n-1]!=={k,p,z})
                $fatal(1,"menu event n=%0d count=%0d got=%h",n,count,events[n-1]);
        end
    endtask
    initial begin
        cycles(3);rn=1;
        // 短毛刺不能触发动作；稳定触摸仅在松手后触发。
        touch=1;position=100;cycles(1);touch=0;cycles(3);
        if(count!=0)$fatal(1,"short touch accepted");
        tap(100);expect_event(1,0,0,0);
        // 采集器先报告active、稍后更新位置，不能误用旧的中间位置。
        touch=1;position=1536;cycles(1);position=100;cycles(6);touch=0;cycles(3);
        expect_event(2,0,0,0);
        touch=1;position=1100;cycles(5);
        repeat(5)begin position=765;cycles(1);position=775;cycles(1);end
        touch=0;cycles(3);expect_event(3,0,0,1);
        // 左区长按只打开一次总菜单；保持/松开都不能又选择第一项。
        touch=1;position=100;cycles(16);expect_event(4,2,0,0);
        if(!main_menu)$fatal(1,"long press did not enter root menu");
        cycles(20);touch=0;cycles(3);
        if(count!=4 || !main_menu)$fatal(1,"long release selected extra item");
        tap(2000);expect_event(5,1,2,2);
        if(main_menu || page!=2)$fatal(1,"page selection failed");
        tap(100);expect_event(6,0,2,0);
        ready=0;tap(2800);
        if(!valid || zone!=3)$fatal(1,"pending action missing");
        touch=1;position=100;cycles(5);ready=1;cycles(4);touch=0;cycles(3);
        expect_event(7,0,2,3);
        if(valid)$fatal(1,"blocked touch leaked a second action");
        touch=1;position=2000;cycles(6);fault=1;cycles(1);touch=0;cycles(3);
        fault=0;cycles(3);
        if(count!=7)$fatal(1,"sensor fault interpreted as menu release");
        ready=0;tap(2000);rn=0;cycles(3);
        if(valid || page!=0 || main_menu)$fatal(1,"reset did not clear pending UI state");
        rn=1;ready=1;cycles(3);
        $display("SLIDER MENU PASS debounce, position settling, hysteresis, long release, backpressure and reset");
        $finish;
    end
    initial begin #100000;$fatal(1,"menu test timeout");end
endmodule
