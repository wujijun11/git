`timescale 1ns/1ps
// 小时基验证导航；四页执行请求独立核对，忙/错误不伪装成功。
module tb_menu_hierarchy;
    reg clk=0;always #5 clk=~clk;
    reg rn=0,touch=0,fault=0,ready=1,busy=0,done=0;
    reg [7:0] error=0;
    reg [11:0] position=0;
    wire valid,wave,reset_expression,fx_write,pv;
    wire [1:0] kind,page,zone,expression_mode,fx_value,preview;
    wire [3:0] view;
    wire [7:0] displayed_error;
    wire [11:0] control_position;
    menu_hierarchy #(.DEBOUNCE_CYCLES(3),.LONG_PRESS_CYCLES(9),.IDLE_CYCLES(10000)) dut(
        .clk(clk),.rst_n(rn),.touch_active(touch),.touch_fault(fault),.position(position),
        .request_valid(valid),.request_ready(ready),.request_kind(kind),.request_page(page),.request_zone(zone),
        .action_busy(busy),.action_done(done),.action_error(error),.display_error(displayed_error),
        .fx_write(fx_write),.fx_value(fx_value),.expression_reset(reset_expression),
        .view(view),.expression_mode(expression_mode),.waveform_view(wave),
        .preview_zone(preview),.position_valid(pv),.control_position(control_position));
    integer requests=0,fxs=0,resets=0,positions=0;
    reg stalled=0;reg [5:0] saved;
    always @(posedge clk)if(rn)begin
        if(stalled && (!valid || {kind,page,zone}!==saved))$fatal(1,"unstable menu payload under backpressure");
        stalled<=valid && !ready;saved<={kind,page,zone};
        if(valid && ready)requests=requests+1;
        if(fx_write)fxs=fxs+1;if(reset_expression)resets=resets+1;if(pv)positions=positions+1;
    end else stalled<=0;
    task cycles(input integer n);repeat(n)@(negedge clk);endtask
    task tap(input integer z);begin position=z*768+100;touch=1;cycles(7);touch=0;cycles(6);end endtask
    task hold_left;begin position=0;touch=1;cycles(18);touch=0;cycles(5);end endtask
    task root;begin
        if(wave)begin tap(2);if(view!=0)$fatal(1,"wake did not select continuous volume");end
        hold_left;if(view!=1 || wave)$fatal(1,"root missing");
    end endtask
    task complete(input integer status);begin error=status;done=1;cycles(1);done=0;cycles(3);end endtask
    task expect_request(input integer p,z);
        begin
            if(!valid || kind!=0 || page!=p || zone!=z)$fatal(1,"wrong request page=%d zone=%d",page,zone);
        end
    endtask
    integer before_requests,n;
    initial begin
        cycles(3);rn=1;cycles(3);
        if(view!=0 || expression_mode!=0)$fatal(1,"default volume missing");
        root;tap(0);if(view!=2 || wave)$fatal(1,"sound category missing");
        tap(0);if(view!=3 || wave)$fatal(1,"timbre page missing");
        ready=0;tap(3);expect_request(0,3);cycles(20);expect_request(0,3);
        if(wave)$fatal(1,"waveform before command acceptance");
        ready=1;cycles(3);busy=1;cycles(100);if(wave)$fatal(1,"busy hidden");
        busy=0;complete(0);if(!wave || view!=0)$fatal(1,"success did not return waveform");
        before_requests=requests;tap(3);
        if(view!=0 || expression_mode!=0 || requests!=before_requests)$fatal(1,"wake tap executed fourth option");
        // 波形左端长触的整次手势只调参数；再次触摸才开菜单。
        cycles(10005);position=0;touch=1;cycles(30);
        if(view!=0 || requests!=before_requests)$fatal(1,"wake hold opened root");
        touch=0;cycles(5);root;tap(0);tap(1);
        ready=0;tap(0);expect_request(1,0);ready=1;cycles(3);complete(3);
        if(wave || displayed_error!=3)$fatal(1,"failure was shown as successful waveform");
        cycles(11000);if(wave)$fatal(1,"error hidden by timeout");
        hold_left;if(displayed_error!=0)$fatal(1,"navigation did not clear stale error");
        tap(0);tap(2);if(view!=5)$fatal(1,"effects menu missing");
        tap(2);if(fxs!=1 || fx_value!=2 || !wave)$fatal(1,"effect selection missing");
        // 表情选择互相独立，闲置10秒后仍恢复刚选的控制模式。
        root;tap(1);if(view!=6)$fatal(1,"expression menu missing");
        tap(1);if(view!=0 || expression_mode!=1 || wave)$fatal(1,"bend selection missing");
        cycles(9990);if(wave)$fatal(1,"ten second timeout early");
        cycles(20);if(!wave)$fatal(1,"ten second timeout missing");
        tap(2);if(expression_mode!=1 || view!=0 || wave)$fatal(1,"bend not restored on wake");
        root;tap(1);tap(2);if(expression_mode!=2)$fatal(1,"vibrato missing");
        root;tap(1);tap(3);if(resets!=1 || expression_mode!=0)$fatal(1,"expression reset missing");
        root;tap(2);ready=0;tap(2);expect_request(2,2);ready=1;cycles(3);complete(0);
        root;tap(3);ready=0;tap(3);expect_request(3,3);ready=1;cycles(3);complete(0);
        // 右长按只退出，保留已有第四区预览逻辑，不执行第四项。
        root;tap(2);before_requests=requests;position=3000;touch=1;cycles(25);touch=0;cycles(6);
        if(view!=0 || requests!=before_requests)$fatal(1,"right hold became fourth action");
        root;tap(0);tap(3);if(view!=1)$fatal(1,"sound return missing");
        touch=1;position=2000;cycles(7);fault=1;cycles(2);touch=0;cycles(5);fault=0;cycles(5);
        if(requests!=before_requests)$fatal(1,"fault became menu selection");
        rn=0;cycles(3);rn=1;cycles(3);
        if(view!=0 || expression_mode!=0 || valid || wave)$fatal(1,"reset state invalid");
        $display("MENU HIERARCHY PASS four categories, nested sound, expressions, ten-second wave, success/error, wake, backpressure and reset");
        $finish;
    end
    initial begin #1000000;$fatal(1,"hierarchy timeout");end
endmodule
