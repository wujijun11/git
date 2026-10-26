`timescale 1ns/1ps
// 直接曲谱经真实64声部分配器：全音域、>25种音高、64并发、反压和完整停止。
module tb_direct_score;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,cv=0,allow_event=1;
    reg [7:0] op=0;reg [79:0] p=0;
    wire cr,ev,er,eon,playing,guide;
    wire [7:0] status;wire [5:0] es;wire [6:0] en,vel;
    wire [1:0] et;wire [24:0] lights;
    reg [174:0] mapping;reg [1:0] timbre=2;
    wire alloc_er,cmd_valid,cmd_on;wire [5:0] cmd_voice;
    wire [6:0] cmd_note,cmd_velocity,active_count;
    wire [1:0] cmd_timbre;wire [63:0] held_mask;
    reg done_valid=0;reg [5:0] done_voice=0;wire done_ready;
    wire full_pulse,ignored_pulse,done_error;
    assign er=allow_event && alloc_er;
    performance_controller #(.CLK_HZ(1000),.SCORE_CAPACITY(256),.RECORD_CAPACITY(4),.DIRECT_SCORE_ENABLE(1)) dut(
        .clk(clk),.rst_n(rst_n),.command_valid(cv),.command_ready(cr),.command_opcode(op),.command_payload(p),
        .command_status(status),.action_busy(),.record_valid(1'b0),.record_on(1'b0),.record_source(6'd25),
        .record_note(7'd60),.record_velocity(7'd100),.record_timbre(2'd2),
        .event_valid(ev),.event_ready(er),.event_on(eon),.event_source(es),.event_note(en),
        .event_velocity(vel),.event_timbre(et),.key_map_flat(mapping),.current_timbre(timbre),
        .guide_mask(lights),.playing(playing),.recording(),.guide_active(guide),.overflow_sticky(),
        .record_count(),.score_position(),.record_read_index(16'd0),.record_read_valid(),.row_payload());
    voice_allocator_v2 alloc(.clk(clk),.rst_n(rst_n),.event_valid(ev && allow_event),.event_ready(alloc_er),
        .event_on(eon),.event_source(es),.event_note(en),.event_velocity(vel),.event_timbre(et),
        .cmd_valid(cmd_valid),.cmd_ready(1'b1),.cmd_on(cmd_on),.cmd_voice(cmd_voice),.cmd_note(cmd_note),
        .cmd_velocity(cmd_velocity),.cmd_timbre(cmd_timbre),.done_valid(done_valid),.done_ready(done_ready),
        .done_voice(done_voice),.active_count(active_count),.active_mask(),.held_mask(held_mask),
        .full_pulse(full_pulse),.ignored_pulse(ignored_pulse),.done_error_pulse(done_error));
    // 本测试用一拍完成释放的假音源；真实ADSR尾音由原音频回归覆盖。
    always @(posedge clk) begin
        if(!rst_n)done_valid<=0;
        else begin
            if(done_valid && done_ready)done_valid<=0;
            if(cmd_valid && !cmd_on)begin done_valid<=1;done_voice<=cmd_voice;end
        end
    end
    integer ons=0,offs=0;reg stalled=0;reg [24:0] previous;
    always @(posedge clk)if(rst_n)begin
        if(stalled && (!ev || {eon,es,en,vel,et}!==previous))$fatal(1,"stalled direct event changed");
        stalled=ev&&!er;previous={eon,es,en,vel,et};
        if(ev&&er)begin
            if(es!=62)$fatal(1,"wrong source");
            if(eon)ons=ons+1;else offs=offs+1;
        end
        if(lights!=0 || guide)$fatal(1,"direct score enabled key guide");
        if(full_pulse || ignored_pulse || done_error)$fatal(1,"allocator error");
    end else stalled=0;
    task issue(input [7:0] code,input [79:0] data,input [7:0] expected);
        begin
            @(negedge clk);op=code;p=data;cv=1;#1;
            if(!cr || status!==expected)$fatal(1,"command %h got %0d expected %0d",code,status,expected);
            @(negedge clk);cv=0;
        end
    endtask
    function [79:0] row(input integer index,input integer delta,input integer note,input integer onoff);
        reg [79:0] value;
        begin value=0;value[15:0]=index;value[47:16]=delta;value[55:48]=note;
            value[63:56]=onoff?96:0;value[64]=onoff;value[72]=1;row=value;end
    endfunction
    task drain;
        begin
            wait(!playing && !dut.stopping && !ev);wait(active_count==0);
            repeat(3)@(negedge clk);
            if(dut.direct_held!=0 || held_mask!=0)$fatal(1,"held notes after stop");
        end
    endtask
    integer i,base_ons,base_offs;reg [79:0] bad;
    initial begin
        for(i=0;i<25;i=i+1)mapping[i*7+:7]=60+i;
        repeat(5)@(negedge clk);rst_n=1;
        // 协议非法值、混合格式、错误提交及残缺上传不得播放。
        issue(6,row(0,0,128,1),1);
        issue(6,row(0,0,127,1),0);
        bad=row(1,0,0,1);bad[72]=0;issue(6,bad,1);
        issue(7,80'd1,1);issue(7,80'h20002,1);issue(4,80'd1,1);
        issue(7,80'h10000,0);
        // 先后播放全部128个MIDI音高，映射始终不变。
        for(i=0;i<128;i=i+1)begin issue(6,row(i*2,0,i,1),0);issue(6,row(i*2+1,200,i,0),0);end
        issue(7,80'h20100,0);issue(4,80'd6,1);issue(4,80'd1,0);
        drain();if(ons!=128 || offs!=128)$fatal(1,"all-pitch event count %0d/%0d",ons,offs);
        // 64不同音高同时按住；没有复制64份HDL源，仅保存128位持有表。
        for(i=0;i<64;i=i+1)issue(6,row(i,0,32+i,1),0);
        issue(7,80'h20040,0);issue(4,80'd1,0);
        wait(ons==192);wait(active_count==64); // 文件结束自动释放，需要暂时挡住最后一次握手后的释放
        drain();if(offs!=192)$fatal(1,"64-note final drain mismatch");
        // 反压时停止：已呈现的NoteOn仍完成握手，再发对应NoteOff，不重发。
        issue(6,row(0,0,127,1),0);issue(6,row(1,100000,0,1),0);issue(7,80'h20002,0);
        allow_event=0;base_ons=ons;base_offs=offs;issue(4,80'd1,0);wait(ev);
        repeat(12)@(negedge clk);timbre=1;issue(4,80'd0,0);issue(4,80'd1,2);
        allow_event=1;drain();if(ons!=base_ons+1 || offs!=base_offs+1)$fatal(1,"stop during stall mismatch");
        // 重新开始采新音色；复位同时清空持有与分配状态。
        issue(4,80'd1,0);wait(cmd_valid&&cmd_on);if(cmd_timbre!=1)$fatal(1,"board timbre not selected");
        @(negedge clk);rst_n=0;repeat(3)@(negedge clk);rst_n=1;
        repeat(5)@(negedge clk);if(dut.direct_held!=0 || active_count!=0)$fatal(1,"reset left active");
        $display("DIRECT SCORE PASS 128 pitches, 64 held voices, source isolation, format guard, backpressure, stop, restart, board timbre and reset");$finish;
    end
    initial begin #3000000;$fatal(1,"direct score timeout ons=%0d offs=%0d",ons,offs);end
endmodule
