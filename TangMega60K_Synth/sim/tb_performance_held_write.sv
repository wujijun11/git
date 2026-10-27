`include "sim/performance_held_write_reference.v"
`timescale 1ns/1ps
// Reduced capacities shorten this verification only. Production defaults stay
// SCORE_CAPACITY=256 / RECORD_CAPACITY=1024. Both lanes use the real controller.
module held_write_equivalence_lane #(parameter REFERENCE=0)(
    input wire clk,rst_n,cmd_valid,input wire [7:0] cmd_seq,cmd_opcode,
    input wire [79:0] cmd_payload,input wire rsp_ready,note_ready,expr_ready,event_ready,
    input wire local_valid,input wire [7:0] local_action,input wire inhibit,
    input wire record_valid,record_on,input wire [5:0] record_source,
    input wire [6:0] record_note,record_velocity,input wire [1:0] record_timbre,
    input wire direct_valid,input wire [7:0] direct_opcode,input wire [79:0] direct_payload,
    output wire cmd_ready,rsp_valid,local_ready,perf_cv,playing,recording,guide_active,
    output wire [7:0] rsp_seq,rsp_opcode,output wire [79:0] rsp_payload,
    output wire [1023:0] public_outputs
);
    wire router_ready,remote_ev,remote_on,expr_valid,perf_ready,perf_action_busy,panic;
    wire [5:0] remote_source;
    wire [6:0] remote_note,remote_velocity;
    wire [1:0] remote_timbre,timbre,fx;
    wire [2:0] expr_mask;
    wire [11:0] expr_gain;
    wire signed [12:0] expr_bend;
    wire [7:0] expr_vibrato,perf_co,perf_status;
    wire [79:0] perf_cp,read_row;
    wire perf_pending;
    wire [174:0] mapping;
    wire [15:0] record_count,score_position,read_index;
    wire read_valid,perf_ev,perf_on,overflow;
    wire [5:0] perf_source;
    wire [6:0] perf_note,perf_velocity;
    wire [1:0] perf_timbre;
    wire [24:0] guide_mask;
    assign cmd_ready=router_ready && !inhibit;
    generate if(REFERENCE)begin: old_router
        remote_command_router_reference router(
            .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid&&!inhibit),.cmd_ready(router_ready),
            .cmd_seq(cmd_seq),.cmd_opcode(cmd_opcode),.cmd_payload(cmd_payload),
            .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_seq(rsp_seq),.rsp_opcode(rsp_opcode),.rsp_payload(rsp_payload),
            .event_valid(remote_ev),.event_ready(note_ready),.event_on(remote_on),.event_source(remote_source),
            .event_note(remote_note),.event_velocity(remote_velocity),.event_timbre(remote_timbre),
            .expr_valid(expr_valid),.expr_ready(expr_ready),.expr_mask(expr_mask),.expr_gain(expr_gain),
            .expr_bend(expr_bend),.expr_vibrato(expr_vibrato),
            .performance_valid(perf_cv),.performance_ready(perf_ready),.performance_opcode(perf_co),
            .performance_payload(perf_cp),.performance_status(perf_status),
            .key_map_flat(mapping),.current_timbre(timbre),.effect_mode(fx),.panic_pulse(panic),
            .active_count(7'd4),.playing(playing),.recording(recording),.guide_active(guide_active),
            .overflow_sticky(overflow),.record_count(record_count),.score_position(score_position),
            .underrun_count(32'd0),.record_read_index(read_index),.record_read_valid(read_valid),.record_read_payload(read_row));
        assign perf_pending=perf_cv;
    end else begin: new_router
        remote_command_router router(
            .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid&&!inhibit),.cmd_ready(router_ready),
            .cmd_seq(cmd_seq),.cmd_opcode(cmd_opcode),.cmd_payload(cmd_payload),
            .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_seq(rsp_seq),.rsp_opcode(rsp_opcode),.rsp_payload(rsp_payload),
            .event_valid(remote_ev),.event_ready(note_ready),.event_on(remote_on),.event_source(remote_source),
            .event_note(remote_note),.event_velocity(remote_velocity),.event_timbre(remote_timbre),
            .expr_valid(expr_valid),.expr_ready(expr_ready),.expr_mask(expr_mask),.expr_gain(expr_gain),
            .expr_bend(expr_bend),.expr_vibrato(expr_vibrato),
            .performance_valid(perf_cv),.performance_pending(perf_pending),.performance_ready(perf_ready),.performance_opcode(perf_co),
            .performance_payload(perf_cp),.performance_status(perf_status),
            .key_map_flat(mapping),.current_timbre(timbre),.effect_mode(fx),.panic_pulse(panic),
            .active_count(7'd4),.playing(playing),.recording(recording),.guide_active(guide_active),
            .overflow_sticky(overflow),.record_count(record_count),.score_position(score_position),
            .underrun_count(32'd0),.record_read_index(read_index),.record_read_valid(read_valid),.record_read_payload(read_row));
    end endgenerate
    assign local_ready=rst_n && !perf_cv && perf_ready && !perf_action_busy && !inhibit && !panic;
    wire [7:0] selected_opcode=perf_pending ? perf_co : 8'h04;
    wire [79:0] selected_payload=perf_pending ? perf_cp : {72'd0,local_action};
    // Direct commands run only with both routers idle. They independently
    // exercise adjacent controller write/commit edges, which UART packets
    // cannot present on successive controller clocks.
    generate if (REFERENCE) begin: frozen_write
    performance_held_write_reference #(.CLK_HZ(1000),.SCORE_CAPACITY(8),.RECORD_CAPACITY(4)) performance(
        .clk(clk),.rst_n(rst_n),
        .command_valid(direct_valid || perf_cv || (local_valid && !inhibit && !panic)),.command_ready(perf_ready),
        .command_opcode(direct_valid ? direct_opcode : selected_opcode),
        .command_payload(direct_valid ? direct_payload : selected_payload),.command_status(perf_status),.action_busy(perf_action_busy),
        .record_valid(record_valid),.record_on(record_on),.record_source(record_source),.record_note(record_note),
        .record_velocity(record_velocity),.record_timbre(record_timbre),
        .event_valid(perf_ev),.event_ready(event_ready),.event_on(perf_on),.event_source(perf_source),
        .event_note(perf_note),.event_velocity(perf_velocity),.event_timbre(perf_timbre),
        .key_map_flat(mapping),.current_timbre(timbre),.guide_mask(guide_mask),
        .playing(playing),.recording(recording),.guide_active(guide_active),.overflow_sticky(overflow),
        .record_count(record_count),.score_position(score_position),.record_read_index(read_index),.record_read_valid(read_valid),.row_payload(read_row));
    end else begin: candidate_write
    performance_controller #(.CLK_HZ(1000),.SCORE_CAPACITY(8),.RECORD_CAPACITY(4)) performance(
        .clk(clk),.rst_n(rst_n),
        .command_valid(direct_valid || perf_cv || (local_valid && !inhibit && !panic)),.command_ready(perf_ready),
        .command_opcode(direct_valid ? direct_opcode : selected_opcode),
        .command_payload(direct_valid ? direct_payload : selected_payload),.command_status(perf_status),.action_busy(perf_action_busy),
        .record_valid(record_valid),.record_on(record_on),.record_source(record_source),.record_note(record_note),
        .record_velocity(record_velocity),.record_timbre(record_timbre),
        .event_valid(perf_ev),.event_ready(event_ready),.event_on(perf_on),.event_source(perf_source),
        .event_note(perf_note),.event_velocity(perf_velocity),.event_timbre(perf_timbre),
        .key_map_flat(mapping),.current_timbre(timbre),.guide_mask(guide_mask),
        .playing(playing),.recording(recording),.guide_active(guide_active),.overflow_sticky(overflow),
        .record_count(record_count),.score_position(score_position),.record_read_index(read_index),.record_read_valid(read_valid),.row_payload(read_row));
    end endgenerate
    assign public_outputs={cmd_ready,rsp_valid,rsp_seq,rsp_opcode,rsp_payload,
        remote_ev,remote_on,remote_source,remote_note,remote_velocity,remote_timbre,
        expr_valid,expr_mask,expr_gain,expr_bend,expr_vibrato,perf_cv,perf_co,perf_cp,
        mapping,timbre,fx,panic,read_index,local_ready,perf_ready,perf_status,perf_action_busy,
        perf_ev,perf_on,perf_source,perf_note,perf_velocity,perf_timbre,
        guide_mask,playing,recording,guide_active,overflow,record_count,score_position,read_valid,read_row};
endmodule

module tb_performance_held_write;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,cmd_valid=0,rsp_ready=0,note_ready=1,expr_ready=1,event_ready=1;
    reg [7:0] cmd_seq=0,cmd_opcode=0,local_action=0;
    reg [79:0] cmd_payload=0;
    reg local_valid=0,inhibit=0,record_valid=0,record_on=0;
    reg [5:0] record_source=25;
    reg [6:0] record_note=60,record_velocity=100;
    reg [1:0] record_timbre=0;
    reg direct_valid=0;
    reg [7:0] direct_opcode=0;
    reg [79:0] direct_payload=0;
    wire nc,nr,nl,np,nplaying,nrecording,nguide;
    wire oc,orr,ol,op,oplaying,orecording,oguide;
    wire [7:0] ns,no,os,oo;
    wire [79:0] nresponse,oresponse;
    wire [1023:0] npublic,opublic;
    held_write_equivalence_lane #(.REFERENCE(0)) optimized(
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_seq(cmd_seq),.cmd_opcode(cmd_opcode),.cmd_payload(cmd_payload),
        .rsp_ready(rsp_ready),.note_ready(note_ready),.expr_ready(expr_ready),.event_ready(event_ready),
        .local_valid(local_valid),.local_action(local_action),.inhibit(inhibit),
        .record_valid(record_valid),.record_on(record_on),.record_source(record_source),.record_note(record_note),
        .record_velocity(record_velocity),.record_timbre(record_timbre),
        .direct_valid(direct_valid),.direct_opcode(direct_opcode),.direct_payload(direct_payload),
        .cmd_ready(nc),.rsp_valid(nr),.local_ready(nl),.perf_cv(np),.playing(nplaying),.recording(nrecording),.guide_active(nguide),
        .rsp_seq(ns),.rsp_opcode(no),.rsp_payload(nresponse),.public_outputs(npublic));
    held_write_equivalence_lane #(.REFERENCE(1)) original(
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_seq(cmd_seq),.cmd_opcode(cmd_opcode),.cmd_payload(cmd_payload),
        .rsp_ready(rsp_ready),.note_ready(note_ready),.expr_ready(expr_ready),.event_ready(event_ready),
        .local_valid(local_valid),.local_action(local_action),.inhibit(inhibit),
        .record_valid(record_valid),.record_on(record_on),.record_source(record_source),.record_note(record_note),
        .record_velocity(record_velocity),.record_timbre(record_timbre),
        .direct_valid(direct_valid),.direct_opcode(direct_opcode),.direct_payload(direct_payload),
        .cmd_ready(oc),.rsp_valid(orr),.local_ready(ol),.perf_cv(op),.playing(oplaying),.recording(orecording),.guide_active(oguide),
        .rsp_seq(os),.rsp_opcode(oo),.rsp_payload(oresponse),.public_outputs(opublic));
    integer cycles=0,remote_accepts=0,local_accepts=0,acks=0,perf_edges=0,stalled_acks=0;
    integer reset_in_perf=0,direct_writes=0,direct_commits=0,contended_perf=0,record_edges=0;
    bit oracle_negative;
    initial oracle_negative=$test$plusargs("ORACLE_NEGATIVE");
    task compare_state;
        integer row;
        begin
            if(npublic!==(opublic ^ ((oracle_negative && cycles==10) ? 1024'd1 : 1024'd0)))
                $fatal(1,"router/performance output mismatch cycle=%0d",cycles);
            if({optimized.candidate_write.performance.row_written,optimized.candidate_write.performance.clear_written,optimized.candidate_write.performance.selected_builtin,
                optimized.candidate_write.performance.committed_count,optimized.candidate_write.performance.run_count,optimized.candidate_write.performance.mode,
                optimized.candidate_write.performance.held,optimized.candidate_write.performance.stopping,optimized.candidate_write.performance.tick_accumulator,
                optimized.candidate_write.performance.time_ms,optimized.candidate_write.performance.due_ms,optimized.candidate_write.performance.last_record_ms,
                optimized.candidate_write.performance.unsupported_record_source}!==
               {original.frozen_write.performance.row_written,original.frozen_write.performance.clear_written,original.frozen_write.performance.selected_builtin,
                original.frozen_write.performance.committed_count,original.frozen_write.performance.run_count,original.frozen_write.performance.mode,
                original.frozen_write.performance.held,original.frozen_write.performance.stopping,original.frozen_write.performance.tick_accumulator,
                original.frozen_write.performance.time_ms,original.frozen_write.performance.due_ms,original.frozen_write.performance.last_record_ms,
                original.frozen_write.performance.unsupported_record_source})
                $fatal(1,"router/performance metadata mismatch cycle=%0d",cycles);
            for(row=0;row<8;row=row+1)
                if(optimized.candidate_write.performance.row_written[row] && optimized.candidate_write.performance.score_ram[row]!==original.frozen_write.performance.score_ram[row])
                    $fatal(1,"router/performance uploaded row mismatch index=%0d",row);
            for(row=0;row<25;row=row+1)
                if({optimized.candidate_write.performance.held_note[row],optimized.candidate_write.performance.held_timbre[row]}!==
                   {original.frozen_write.performance.held_note[row],original.frozen_write.performance.held_timbre[row]})
                    $fatal(1,"router/performance held metadata mismatch key=%0d",row);
        end
    endtask
    always @(posedge clk)begin
        cycles=cycles+1;
        if(rst_n)begin
            if(cmd_valid&&nc)remote_accepts=remote_accepts+1;
            if(local_valid&&nl)local_accepts=local_accepts+1;
            if(nr&&rsp_ready)acks=acks+1;
            if(nr&&!rsp_ready)stalled_acks=stalled_acks+1;
            if(np)perf_edges=perf_edges+1;
            if(np&&local_valid)begin
                contended_perf=contended_perf+1;
                if(nl)$fatal(1,"local ready bypassed remote performance priority");
            end
            if(record_valid&&nrecording)record_edges=record_edges+1;
            if(direct_valid&&direct_opcode==6)direct_writes=direct_writes+1;
            if(direct_valid&&direct_opcode==7)direct_commits=direct_commits+1;
        end
        #1;compare_state();
    end
    task idle_clocks(input integer count);
        integer k;
        begin for(k=0;k<count;k=k+1)begin @(posedge clk);#2;end end
    endtask
    task reset_case;
        begin
            @(negedge clk);rst_n=0;cmd_valid=0;rsp_ready=0;local_valid=0;inhibit=0;record_valid=0;direct_valid=0;
            note_ready=1;expr_ready=1;event_ready=1;
            idle_clocks(3);@(negedge clk);rst_n=1;idle_clocks(1);
        end
    endtask
    task launch(input [7:0] opcode,input [79:0] payload);
        integer k;
        begin
            k=0;while(!nc&&k<400)begin idle_clocks(1);k=k+1;end
            if(!nc)$fatal(1,"command admission timeout");
            @(negedge clk);cmd_seq=cmd_seq+1;cmd_opcode=opcode;cmd_payload=payload;cmd_valid=1;
            @(posedge clk);#2;
            @(negedge clk);cmd_valid=0;
        end
    endtask
    task wait_ack(input [7:0] status);
        integer k;
        begin
            k=0;while(!nr&&k<400)begin idle_clocks(1);k=k+1;end
            if(!nr||ns!==cmd_seq||no!==8'h80||nresponse!=={64'd0,status,cmd_opcode})
                $fatal(1,"unexpected ACK seq=%0d opcode=%h status=%0d response=%h",cmd_seq,cmd_opcode,status,nresponse);
            // Keep ACK backpressured while exercising its stable payload.
            idle_clocks(4);
            @(negedge clk);rsp_ready=1;@(posedge clk);#2;@(negedge clk);rsp_ready=0;
        end
    endtask
    task issue(input [7:0] opcode,input [79:0] payload,input [7:0] status);
        begin launch(opcode,payload);wait_ack(status);end
    endtask
    task direct_issue(input [7:0] opcode,input [79:0] payload,input [7:0] status);
        begin
            @(negedge clk);direct_valid=1;direct_opcode=opcode;direct_payload=payload;
            #1;if(optimized.perf_status!==status||!optimized.perf_ready)$fatal(1,"direct status expected=%0d got=%0d",status,optimized.perf_status);
            @(posedge clk);#2;
        end
    endtask
    function automatic [79:0] score_row(input integer index,input integer key,input bit on);
        begin score_row={8'd0,7'd0,on,8'd100,key[7:0],32'd0,index[15:0]};end
    endfunction
    reg [31:0] rng;
    function automatic [31:0] next_random(input [31:0] previous);
        reg [31:0] value;
        begin value=previous^(previous<<13);value=value^(value>>17);next_random=value^(value<<5);end
    endfunction
    integer n,k,seed,random_cycles;
    reg [7:0] random_key;
    initial begin
        if(!$value$plusargs("SEED=%d",seed))seed=471833;
        if(!$value$plusargs("RANDOM_CYCLES=%d",random_cycles))random_cycles=10000;
        reset_case();
        // Reset asserted between clocks while the router owns PERF_WAIT must
        // cancel the transaction without replaying it after reset release.
        launch(4,80'd2);@(posedge clk);#2;
        if(!np)$fatal(1,"reset setup did not reach PERF_WAIT");
        #1;rst_n=0;reset_in_perf=reset_in_perf+1;
        #1;compare_state();
        if(np||nr)$fatal(1,"async reset did not cancel pending performance command");
        idle_clocks(3);@(negedge clk);rst_n=1;idle_clocks(3);
        if(nrecording||nr)$fatal(1,"reset replayed record-start command");

        // Remote start must beat a simultaneous local guide-start without
        // consuming the local request or using the local payload as remote.
        launch(4,80'd1);@(posedge clk);#2;
        if(!np)$fatal(1,"competition setup not pending");
        local_valid=1;local_action=6;
        wait_ack(0);local_valid=0;
        if(!nplaying||nrecording)$fatal(1,"remote action lost local competition");
        issue(4,80'd0,0);idle_clocks(10);
        issue(4,80'd2,0);record_valid=1;idle_clocks(3);record_valid=0;
        issue(4,80'd3,0);
        if(optimized.record_count!=3||nrecording)$fatal(1,"event recording control failed");
        issue(4,80'd5,0);idle_clocks(10);

        // The real router path must preserve upload and commit status/metadata.
        reset_case();
        for(n=0;n<8;n=n+1)issue(6,score_row(n,n,n[0]==0),0);
        if(optimized.candidate_write.performance.row_written!==8'hff)$fatal(1,"router uploads missing row");
        issue(7,80'd8,0);
        if(optimized.candidate_write.performance.committed_count!=8||optimized.candidate_write.performance.selected_builtin)$fatal(1,"router commit metadata wrong");
        issue(7,80'd8,1);
        issue(6,score_row(0,0,1),0);issue(7,80'd1,0);
        issue(4,80'd1,0);idle_clocks(20);
        issue(4,80'd0,0);idle_clocks(40);

        // Strict adjacent 06->07 and 07->06 controller edges, including final
        // bitmap clear and reuse rejection, use the shared direct input only.
        reset_case();
        direct_issue(7,80'h10000,0);
        direct_issue(6,score_row(7,7,1),0);
        if(optimized.candidate_write.performance.row_written!==8'h80)$fatal(1,"write after commit lost its row");
        direct_issue(7,80'd8,1);
        for(n=0;n<7;n=n+1)direct_issue(6,score_row(n,n,n[0]==0),0);
        direct_issue(7,80'd8,0);
        direct_issue(7,80'd8,1);
        direct_issue(6,score_row(0,0,1),0);
        direct_issue(7,80'd1,0);
        direct_issue(6,score_row(1,1,0),0);
        if(optimized.candidate_write.performance.row_written!==8'h02)$fatal(1,"adjacent next-epoch write retained old bitmap");
        direct_issue(7,80'd2,1);
        direct_issue(6,score_row(0,0,1),0);direct_issue(7,80'd2,0);
        direct_issue(7,80'd2,1);
        @(negedge clk);direct_valid=0;

        // Fixed-seed concurrent local/remote traffic, ACK/event backpressure,
        // panic inhibition, invalid requests, duplicate commands and recording.
        reset_case();rng=seed;
        for(k=0;k<random_cycles;k=k+1)begin
            @(negedge clk);rng=next_random(rng);
            rsp_ready=rng[0];event_ready=rng[1];note_ready=rng[2];expr_ready=rng[3];
            inhibit=rng[8:5]==0;local_valid=rng[4];local_action=rng[12:9]%9;
            record_valid=rng[13];record_on=rng[14];record_note=rng[21:15];record_source=25+rng[26:22]%25;
            cmd_valid=0;random_key=rng[26:22]%25;
            if(nc&&rng[28:27]!=0)begin
                cmd_valid=1;cmd_seq=cmd_seq+1;
                case(rng[31:29])
                    0:begin cmd_opcode=4;cmd_payload=rng[12:9]%9;end
                    1:begin cmd_opcode=6;cmd_payload=score_row(rng[18:16],rng[23:19]%25,rng[14]);end
                    2:begin cmd_opcode=7;cmd_payload=1+(rng[18:16]);end
                    3:begin cmd_opcode=3;cmd_payload={64'd0,6'd0,rng[16:15],7'd0,rng[17]};end
                    4:begin cmd_opcode=5;cmd_payload={64'd0,1'b0,rng[21:15],random_key};end
                    5:begin cmd_opcode=1;cmd_payload={40'd0,7'd0,rng[14],6'd0,rng[16:15],1'b0,7'd100,1'b0,rng[21:15],8'd0};end
                    6:begin cmd_opcode=4;cmd_payload=5;end
                    default:begin cmd_opcode=8'hff;cmd_payload=0;end
                endcase
            end
            @(posedge clk);#2;
            if(k%997==996)begin
                #1;rst_n=0;cmd_valid=0;local_valid=0;record_valid=0;
                #1;compare_state();idle_clocks(2);@(negedge clk);rst_n=1;
            end
        end
        @(negedge clk);cmd_valid=0;local_valid=0;record_valid=0;inhibit=0;rsp_ready=1;event_ready=1;note_ready=1;expr_ready=1;
        idle_clocks(20);reset_case();
        if(remote_accepts<100||acks<100||perf_edges<30||stalled_acks<100||reset_in_perf!=1||
           direct_writes<10||direct_commits<8||contended_perf<1||record_edges<3)
            $fatal(1,"router/performance missing coverage remote=%0d acks=%0d perf=%0d stalls=%0d resets=%0d writes=%0d commits=%0d contention=%0d record=%0d",remote_accepts,acks,perf_edges,stalled_acks,reset_in_perf,direct_writes,direct_commits,contended_perf,record_edges);
        $display("PERFORMANCE HELD WRITE EQUIVALENCE PASS cycles=%0d random_cycles=%0d seed=%0d remote=%0d local=%0d acks=%0d perf=%0d stalled_acks=%0d reset_in_perf=%0d adjacent_writes=%0d adjacent_commits=%0d contention=%0d record_edges=%0d",cycles,random_cycles,seed,remote_accepts,local_accepts,acks,perf_edges,stalled_acks,reset_in_perf,direct_writes,direct_commits,contended_perf,record_edges);
        $finish;
    end
    initial begin #2000000;$fatal(1,"router/performance equivalence timeout");end
endmodule
