`timescale 1ns/1ps
module tb_slider_expression_control;
    reg clk=0;always #5 clk=~clk;
    reg rn=0,pv=0,touch=0,fault=0,reset_expression=0,ready=1;
    reg [11:0] position=0;reg [1:0] mode=0;
    wire valid;wire [2:0] mask;wire [11:0] gain;wire signed [12:0] bend;wire [7:0] vibrato;
    slider_expression_control dut(.clk(clk),.rst_n(rn),.mode(mode),.position_valid(pv),.position(position),
        .touch_active(touch),.touch_fault(fault),.reset_expression(reset_expression),.expr_valid(valid),
        .expr_ready(ready),.expr_mask(mask),.expr_gain(gain),.expr_bend(bend),.expr_vibrato(vibrato));
    integer g=2048,b=0,v=0,updates=0;
    reg stalled=0;reg [35:0] saved;
    always @(posedge clk)if(rn)begin
        if(stalled && (!valid || {mask,gain,bend,vibrato}!==saved))$fatal(1,"expression bundle changed while stalled");
        stalled<=valid && !ready;saved<={mask,gain,bend,vibrato};
        if(valid && ready)begin
            updates=updates+1;if(mask[0])g=gain;if(mask[1])b=$signed(bend);if(mask[2])v=vibrato;
            if(g<0 || g>2048 || b< -200 || b>200 || v<0 || v>100)$fatal(1,"expression range");
        end
    end else stalled<=0;
    task cycles(input integer n);repeat(n)@(negedge clk);endtask
    task point(input integer m,p);begin mode=m;position=p;touch=1;pv=1;cycles(16);end endtask
    task release_touch;begin touch=0;pv=0;cycles(16);end endtask
    initial begin
        cycles(3);rn=1;cycles(15);if(updates)$fatal(1,"idle changed default expression");
        point(0,1536);if(g<1024 || g>1025 || b || v)$fatal(1,"volume mapping changed pitch");
        release_touch;point(1,0);if(b!= -200 || g<1024 || v)$fatal(1,"bend low endpoint");
        point(1,1536);if(b!=0)$fatal(1,"bend center");
        point(1,3072);if(b!=200)$fatal(1,"bend high endpoint");
        release_touch;if(b!=0 || g<1024)$fatal(1,"bend release did not center or changed gain");
        point(2,1536);if(v!=50 || g<1024 || b)$fatal(1,"vibrato middle");
        point(2,4095);if(v!=100)$fatal(1,"position clamp");release_touch;if(v!=100)$fatal(1,"vibrato did not hold");
        ready=0;point(1,2000);point(1,3000);release_touch;ready=1;cycles(30);
        if(b!=0 || v!=100 || g<1024)$fatal(1,"stalled release lost or fields overwritten");
        point(1,3072);fault=1;cycles(20);if(b!=0)$fatal(1,"fault left bent note");release_touch;fault=0;
        reset_expression=1;cycles(1);reset_expression=0;cycles(20);
        if(b || v || g<1024 || g>1025)$fatal(1,"reset failed or changed volume");
        // 左端短触松手补交的位置，即使raw touch为0也必须能提交音量0。
        mode=0;position=0;pv=1;cycles(1);pv=0;cycles(15);if(g!=0)$fatal(1,"release position lost");
        rn=0;cycles(3);if(valid)$fatal(1,"reset valid");
        $display("SLIDER EXPRESSION PASS masks, endpoints, bend release/fault, vibrato hold, preserved gain and stalled payload");
        $finish;
    end
    initial begin #100000;$fatal(1,"expression timeout");end
endmodule
