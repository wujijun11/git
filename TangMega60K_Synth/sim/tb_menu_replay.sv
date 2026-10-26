`timescale 1ns/1ps
module tb_menu_replay;
    reg clk=0;always #5 clk=~clk;
    reg rn=0,request_valid=0;
    reg [1:0] request_kind=0,request_page=0,request_zone=0;
    wire request_ready,action_valid,action_ready,timbre_valid,prompt_valid,busy;
    wire [7:0] action,status,error;
    wire [1:0] timbre,prompt_code;
    wire signed [6:0] transpose;
    wire playing,recording,guide,overflow,perf_busy;
    wire [15:0] count,score_position;
    wire ev,eon;reg event_ready=1;
    wire [5:0] source;wire [6:0] note,velocity;wire [1:0] tone;
    wire [24:0] guide_mask;
    reg [174:0] mapping;
    reg record_valid=0,record_on=0;
    reg [5:0] record_source=25;
    reg [6:0] record_note=60;
    menu_action_router #(.CLK_HZ(1000),.RETRY_CYCLES(2),.MAX_RETRIES(30)) dispatch(
        .clk(clk),.rst_n(rn),.request_valid(request_valid),.request_ready(request_ready),
        .request_kind(request_kind),.request_page(request_page),.request_zone(request_zone),
        .recording(recording),.playing(playing),.guide_active(guide),
        .timbre_valid(timbre_valid),.timbre(timbre),.transpose(transpose),
        .action_valid(action_valid),.action_ready(action_ready),.action(action),.action_status(status),
        .prompt_valid(prompt_valid),.prompt_code(prompt_code),.last_error(error),.busy(busy));
    performance_controller #(.CLK_HZ(1000)) perf(
        .clk(clk),.rst_n(rn),.command_valid(action_valid),.command_ready(action_ready),
        .command_opcode(8'h04),.command_payload({72'd0,action}),.command_status(status),.action_busy(perf_busy),
        .record_valid(record_valid),.record_on(record_on),.record_source(record_source),
        .record_note(record_note),.record_velocity(7'd100),.record_timbre(2'd2),
        .event_valid(ev),.event_ready(event_ready),.event_on(eon),.event_source(source),
        .event_note(note),.event_velocity(velocity),.event_timbre(tone),
        .key_map_flat(mapping),.current_timbre(2'd2),.guide_mask(guide_mask),
        .playing(playing),.recording(recording),.guide_active(guide),.overflow_sticky(overflow),
        .record_count(count),.score_position(score_position),.record_read_index(16'd0),
        .record_read_valid(),.row_payload());
    integer events=0,replay_starts=0,accepted_actions=0;
    reg [16:0] log_events[0:511];
    reg stalled=0;reg [22:0] previous;
    always @(posedge clk) if(rn) begin
        if(stalled && (!ev || {eon,source,note,velocity,tone}!==previous))
            $fatal(1,"playback event changed while stalled");
        stalled<=ev&&!event_ready;
        previous<={eon,source,note,velocity,tone};
        if(action_valid&&action_ready&&status==0) begin
            accepted_actions=accepted_actions+1;
            if(action==8)replay_starts=replay_starts+1;
        end
        if(ev&&event_ready)begin
            log_events[events]={eon,source,note,tone,1'b0};events=events+1;
        end
    end else stalled<=0;
    task cycles(input integer n);repeat(n)@(negedge clk);endtask
    task command(input [1:0] p,z);
        integer limit;
        begin
            @(negedge clk);request_page=p;request_zone=z;request_valid=1;
            while(!request_ready)@(negedge clk);
            @(negedge clk);request_valid=0;
            limit=0;while(busy&&limit<1000)begin cycles(1);limit=limit+1;end
            if(busy)$fatal(1,"menu action did not finish");
            cycles(2);
        end
    endtask
    task record_event(input bit onoff,input integer key,input integer pitch);
        begin
            @(negedge clk);record_on=onoff;record_source=25+key;record_note=pitch;record_valid=1;
            @(negedge clk);record_valid=0;cycles(4);
        end
    endtask
    task await_idle;
        integer limit;
        begin
            limit=0;while((playing||guide||perf.stopping||ev)&&limit<5000)begin cycles(1);limit=limit+1;end
            if(playing||guide||perf.stopping||ev)$fatal(1,"playback did not release all held notes");
        end
    endtask
    integer before_events,k;
    initial begin
        for(k=0;k<25;k=k+1)mapping[k*7+:7]=60+k;
        cycles(4);rn=1;cycles(2);
        command(2,2);if(error!=1 || playing)$fatal(1,"empty recording not rejected");
        command(0,1);if(timbre!=1)$fatal(1,"timbre map failed");
        command(1,0);if(transpose!=-24)$fatal(1,"negative transpose failed");
        command(2,0);if(!recording)$fatal(1,"record did not start");
        record_event(1,0,60);record_event(1,1,64);
        command(2,0);if(count!=2)$fatal(1,"repeated start erased active recording");
        record_event(0,0,60);record_event(0,1,64);
        command(2,1);if(recording||count!=4)$fatal(1,"record stop/count failed");
        event_ready=0;before_events=events;command(2,2);
        cycles(20);if(!ev)$fatal(1,"playback did not present event");
        event_ready=1;await_idle();
        if(events-before_events!=4)$fatal(1,"record replay lost or duplicated event");
        if(log_events[before_events][16]!=1 || log_events[before_events][9:3]!=60 ||
           log_events[before_events+1][9:3]!=64 || log_events[before_events+2][16]!=0)
            $fatal(1,"record replay contents wrong");
        command(3,0);cycles(12);
        if(!playing)$fatal(1,"built-in score did not start");
        // 播放曲谱中切到录音回放：先停并释放旧音，再执行回放。
        command(2,2);await_idle();
        if(replay_starts!=2 || perf.held!=0 || error!=0)$fatal(1,"score to replay transition failed");
        command(3,2);cycles(8);if(!guide)$fatal(1,"guide did not start");
        command(2,3);await_idle();if(recording)$fatal(1,"global stop left recorder active");
        // 保留既有来源限制：远程来源可记录/导出，但不得伪装实体键位回放。
        command(2,0);record_source=63;record_note=69;record_on=1;record_valid=1;
        cycles(1);record_valid=0;command(2,1);command(2,2);
        if(error!=1 || playing)$fatal(1,"unsupported recording source accepted");
        rn=0;cycles(3);if(busy||recording||ev)$fatal(1,"reset left pending action");
        $display("MENU REPLAY PASS recording, source checks, score, guide, stop, backpressure and transition");$finish;
    end
    initial begin #200000;$fatal(1,"menu replay watchdog");end
endmodule
