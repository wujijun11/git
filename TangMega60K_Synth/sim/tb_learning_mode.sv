`timescale 1ns/1ps
// 使用真实曲谱RAM验证学习；不代替传感器、灯板上板测试。
module tb_learning_mode;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,cv=0;reg [7:0] op=0;reg [79:0] p=0;
    wire cr,ev,guide,playing;wire [7:0] status;
    reg [24:0] touch=0;reg sensor_ready=1;
    wire [24:0] target;wire [79:0] learn;wire [15:0] position;
    reg [174:0] mapping;
    performance_controller #(.CLK_HZ(1000),.SCORE_CAPACITY(64),.RECORD_CAPACITY(4),
        .DIRECT_SCORE_ENABLE(1),.LEARNING_ENABLE(1)) dut(
        .clk(clk),.rst_n(rst_n),.command_valid(cv),.command_ready(cr),.command_opcode(op),.command_payload(p),
        .command_status(status),.record_valid(1'b0),.record_on(1'b0),.record_source(6'd25),
        .record_note(7'd60),.record_velocity(7'd100),.record_timbre(2'd2),
        .event_valid(ev),.event_ready(1'b0),.key_map_flat(mapping),.current_timbre(2'd2),
        .guide_mask(target),.playing(playing),.guide_active(guide),.score_position(position),
        .record_read_index(16'd0),.learning_touch_mask(touch),.learning_touch_ready(sensor_ready),
        .learning_status_payload(learn));
    task cycles(input integer n);repeat(n)@(negedge clk);endtask
    task issue(input [7:0] code,input [79:0] data,input [7:0] expected);
        begin
            @(negedge clk);op=code;p=data;cv=1;#1;
            if(!cr || status!==expected)$fatal(1,"op=%h data=%h status=%d expected=%d",code,data,status,expected);
            @(negedge clk);cv=0;
        end
    endtask
    function [79:0] row(input integer index,input integer delta,input integer key,input integer onoff);
        reg [79:0] value;
        begin value=0;value[15:0]=index;value[47:16]=delta;value[55:48]=key;
            value[63:56]=onoff?96:0;value[64]=onoff;row=value;end
    endfunction
    task expect_target(input [24:0] mask,input integer completed);
        begin cycles(20);
            if(!guide || playing || target!==mask || learn[31:16]!==completed || learn[56:32]!==mask)
                $fatal(1,"target=%h completed=%d pos=%d",target,learn[31:16],position);
        end
    endtask
    always @(posedge clk)if(rst_n && ev)$fatal(1,"learning generated audio event");
    reg [15:0] saved_position;reg [79:0] value;
    initial begin
        for(integer k=0;k<25;k=k+1)mapping[k*7+:7]=60+k;
        cycles(5);rst_n=1;
        issue(6,row(0,12345,0,1),0);issue(6,row(1,200,0,0),0);
        issue(6,row(2,100,0,1),0);issue(6,row(3,200,0,0),0);
        issue(6,row(4,100,2,1),0);issue(6,row(5,0,4,1),0);
        issue(6,row(6,0,7,1),0);issue(6,row(7,200,2,0),0);
        issue(6,row(8,0,4,0),0);issue(6,row(9,0,7,0),0);
        issue(6,row(10,100,24,1),0);issue(7,80'd11,0);
        touch=1;issue(4,9,0);expect_target(1,0);
        if(!learn[10])$fatal(1,"held at start skipped release");
        saved_position=position;cycles(10000);
        if(position!=saved_position || learn[31:16]!=0)$fatal(1,"time advanced lesson");
        issue(4,9,2);issue(6,row(0,0,0,1),2);issue(4,2,2);
        touch=0;cycles(3);touch=2;expect_target(1,0);
        touch=3;expect_target(1,0);
        touch=1;expect_target(1,1);
        cycles(100);if(learn[31:16]!=1)$fatal(1,"held repeated note auto-advanced");
        touch=0;cycles(3);touch=1;expect_target(25'h94,2);
        touch=0;cycles(3);touch=4;expect_target(25'h94,2);
        touch=25'h14;expect_target(25'h94,2);
        sensor_ready=0;touch=25'h94;expect_target(25'h94,2);
        sensor_ready=1;expect_target(25'h94,2);
        touch=0;cycles(3);touch=25'h94;expect_target(25'h1000000,3);
        touch=0;cycles(3);touch=25'h1000000;cycles(25);
        if(guide || target || !learn[12] || learn[31:16]!=4)$fatal(1,"EOF final NoteOn lost");
        touch=0;issue(4,9,0);expect_target(1,0);issue(4,7,0);cycles(10);
        if(guide || target || learn[12])$fatal(1,"stop did not clear");
        issue(4,9,0);issue(4,5,0);cycles(20);if(guide)$fatal(1,"panic failed");
        issue(4,9,0);rst_n=0;cycles(3);rst_n=1;cycles(10);
        if(guide || learn[31:16]!=0)$fatal(1,"reset failed");
        value=row(0,0,127,1);value[72]=1;issue(6,value,0);issue(7,80'h20001,0);issue(4,9,1);
        issue(6,row(0,0,0,0),0);value=row(1,100,24,1);value[63:56]=0;
        issue(6,value,0);issue(7,80'd2,0);issue(4,9,0);cycles(25);
        if(guide || !learn[12] || learn[31:16]!=0)$fatal(1,"empty lesson did not finish");
        $display("LEARNING MODE PASS indefinite wait, repeated pitch, chord, wrong/extra keys, sensor fault, EOF, stop, panic, reset, direct rejection, zero velocity");$finish;
    end
    initial begin #2000000;$fatal(1,"learning timeout");end
endmodule
