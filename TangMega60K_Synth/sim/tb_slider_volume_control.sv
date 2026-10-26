`timescale 1ns/1ps
// 独立整数公式验证全部位置、全gain百分比、反压保持、最新目标与重触摸。
module tb_slider_volume_control;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,position_valid=0,expr_ready=1;
    reg [11:0] position=0,meter_gain=2048;
    wire expr_valid;
    wire [11:0] expr_gain;
    wire [7:0] percent;
    slider_volume_control #(.GAIN_HYSTERESIS(1)) dut(.*);
    gain_percent_meter meter(.clk(clk),.rst_n(rst_n),.gain(meter_gain),.percent(percent));
    integer transactions=0,last_gain=2048;
    reg stalled=0;
    reg [11:0] saved;
    always @(posedge clk) begin
        if(!rst_n) stalled<=0;
        else begin
            if(stalled && (!expr_valid || expr_gain!==saved))
                $fatal(1,"Volume expression changed under backpressure");
            stalled<=expr_valid && !expr_ready;
            saved<=expr_gain;
            if(expr_valid && expr_ready) begin
                if(expr_gain>2048)$fatal(1,"Local volume exceeded neutral gain");
                transactions=transactions+1;
                last_gain=expr_gain;
            end
        end
    end
    task cycles(input integer count);
        repeat(count) @(negedge clk);
    endtask
    task set_position(input integer value);
        begin position=value;position_valid=1;cycles(8);end
    endtask
    integer p,expected,error,previous_gain,before_transactions;
    initial begin
        cycles(3);rst_n=1;cycles(5);
        if(transactions!=0 || percent!=100)$fatal(1,"Startup changed volume");
        previous_gain=0;
        for(p=0;p<=3072;p=p+1)begin
            set_position(p);
            expected=(p*2+1)/3;
            error=last_gain-expected;
            if(error< -1 || error>1 || last_gain<previous_gain)
                $fatal(1,"Position mapping p=%d gain=%d expected=%d",p,last_gain,expected);
            previous_gain=last_gain;
        end
        if(last_gain!=2048)$fatal(1,"Full volume endpoint");
        set_position(4095);if(last_gain!=2048)$fatal(1,"Position clamp failed");
        // 全部4096个Q1.11输入的百分比按独立乘除公式校验。
        for(p=0;p<4096;p=p+1)begin
            meter_gain=p;cycles(3);
            if(percent!=(p*100+1024)/2048)$fatal(1,"Percent error gain=%d",p);
        end
        expr_ready=0;set_position(1500);
        if(!expr_valid)$fatal(1,"No stalled transaction");
        set_position(200);set_position(2300);set_position(3072);
        expr_ready=1;cycles(12);
        if(last_gain!=2048)$fatal(1,"Latest target lost behind stalled transaction");
        position_valid=0;cycles(5);before_transactions=transactions;
        set_position(3072);
        if(transactions<=before_transactions)$fatal(1,"Re-touch could not override App volume");
        position_valid=0;cycles(5);
        expr_ready=0;set_position(0);
        rst_n=0;cycles(2);position_valid=0;rst_n=1;expr_ready=1;cycles(5);
        if(expr_valid || expr_gain!=2048)$fatal(1,"Reset retained a stale gain");
        $display("SLIDER VOLUME CONTROL PASS all positions, 4096 gain values, monotonicity, backpressure, latest target, retouch, reset");
        $finish;
    end
    initial begin #1000000;$fatal(1,"Volume control timeout");end
endmodule
