`timescale 1ns/1ps
// 1024事件回归：跨越旧256上限、完整性校验、满容量播放、反压、停止及复位。
module tb_score_capacity_1024;
    reg clk=0;
    always #5 clk=~clk;
    reg rn=0,cv=0;
    reg [7:0] opcode=0;
    reg [79:0] payload=0;
    wire ready;
    wire [7:0] status;
    reg event_ready=1;
    wire event_valid,event_on,playing;
    wire [5:0] source;
    wire [6:0] note;
    reg [174:0] mapping;
    performance_controller #(.CLK_HZ(1000),.RECORD_CAPACITY(4)) dut(
        .clk(clk),.rst_n(rn),.command_valid(cv),.command_ready(ready),
        .command_opcode(opcode),.command_payload(payload),.command_status(status),.action_busy(),
        .record_valid(1'b0),.record_on(1'b0),.record_source(6'd0),.record_note(7'd0),
        .record_velocity(7'd0),.record_timbre(2'd0),.event_valid(event_valid),.event_ready(event_ready),
        .event_on(event_on),.event_source(source),.event_note(note),.event_velocity(),.event_timbre(),
        .key_map_flat(mapping),.current_timbre(2'd2),.guide_mask(),.playing(playing),.recording(),
        .guide_active(),.overflow_sticky(),.record_count(),.score_position(),
        .record_read_index(16'd0),.record_read_valid(),.row_payload());
    integer count=0,cycle=0;
    reg check_sequence=0,stalled=0;
    reg [13:0] previous;
    always @(posedge clk)if(rn)begin
        cycle=cycle+1;
        if(stalled && (!event_valid || {event_on,source,note}!==previous))
            $fatal(1,"1024 playback changed stalled event");
        stalled<=event_valid&&!event_ready;
        previous<={event_on,source,note};
        if(check_sequence && event_valid && event_ready)begin
            if(event_on!==!(count%2) || source!=(count/2)%25 || note!=60+(count/2)%25)
                $fatal(1,"1024 sequence mismatch event=%0d source=%0d note=%0d on=%0d",count,source,note,event_on);
            count=count+1;
        end
    end else begin
        stalled<=0;
        cycle=0;
    end
    always @(negedge clk)event_ready=(cycle%13>=4);
    task issue(input [7:0] op,input [79:0] data,input [7:0] expected);
        begin
            @(negedge clk);cv=1;opcode=op;payload=data;#1;
            if(!ready || status!==expected)$fatal(1,"command %h expected %0d got %0d",op,expected,status);
            @(posedge clk);@(negedge clk);cv=0;
        end
    endtask
    function [79:0] row_data;
        input integer index;
        reg [79:0] data;
        begin
            data=0;
            data[15:0]=index;
            data[47:16]=index==0?0:1;
            data[55:48]=(index/2)%25;
            data[63:56]=100;
            data[64]=!(index%2);
            row_data=data;
        end
    endfunction
    integer index;
    initial begin
        for(index=0;index<25;index=index+1)mapping[index*7 +:7]=60+index;
        repeat(5)@(negedge clk);rn=1;
        // 最大地址1023合法，1024越界；索引256不再是越界。
        issue(6,row_data(1024),1);
        issue(6,row_data(1023),0);
        issue(6,row_data(256),0);
        issue(7,80'd1024,1);
        issue(4,80'd1,1);
        issue(4,80'd6,1);
        for(index=0;index<1024;index=index+1)issue(6,row_data(index),0);
        issue(7,80'd1024,0);
        check_sequence=1;
        issue(4,80'd1,0);
        wait(count==1024);
        wait(!playing);
        repeat(6)@(negedge clk);
        if(count!=1024 || dut.held!=0)$fatal(1,"full score left held notes or duplicated events");
        check_sequence=0;
        issue(4,80'd1,0);
        wait(dut.held!=0);
        issue(4,80'd0,0);
        wait(!playing && !dut.stopping && !event_valid);
        if(dut.held!=0)$fatal(1,"stop did not release score notes");
        // 新上传写入后使旧提交失效，断线/中断时不能播放混杂的半份曲谱。
        issue(6,row_data(0),0);
        issue(4,80'd1,1);
        issue(4,80'd6,1);
        issue(7,80'd1024,1);
        issue(7,80'h10000,0);
        rn=0;repeat(3)@(negedge clk);rn=1;
        issue(7,80'd1024,1);
        $display("SCORE 1024 PASS full upload/playback, 256/1023/1024 boundaries, partial-upload guard, bitmap, backpressure, stop and reset");
        $finish;
    end
    initial begin #1000000;$fatal(1,"1024 score test timeout count=%0d",count);end
endmodule
