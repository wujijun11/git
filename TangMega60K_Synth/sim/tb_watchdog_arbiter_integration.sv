`timescale 1ns/1ps
// Actual router + watchdog + arbiter + FIFO with the full-system wiring.
// The consumer deliberately stalls; no producer or event queue is stubbed.
module tb_watchdog_arbiter_integration;
    reg clk=0; always #5 clk=!clk;
    reg rst_n=0, cmd_valid=0;
    wire cmd_ready,router_ready;
    reg [7:0] cmd_seq=0,cmd_opcode=0;
    reg [79:0] cmd_payload=0;
    wire rsp_valid; wire [7:0] rsp_seq,rsp_opcode; wire [79:0] rsp_payload;
    wire remote_valid,remote_ready,remote_on;
    wire [5:0] remote_source; wire [6:0] remote_note,remote_velocity; wire [1:0] remote_timbre;
    wire releasing;
    assign cmd_ready=router_ready && !releasing;
    remote_command_router router(.clk(clk),.rst_n(rst_n),
        .cmd_valid(cmd_valid && !releasing),.cmd_ready(router_ready),
        .cmd_seq(cmd_seq),.cmd_opcode(cmd_opcode),.cmd_payload(cmd_payload),
        .rsp_valid(rsp_valid),.rsp_ready(1'b1),.rsp_seq(rsp_seq),.rsp_opcode(rsp_opcode),.rsp_payload(rsp_payload),
        .event_valid(remote_valid),.event_ready(remote_ready),.event_on(remote_on),
        .event_source(remote_source),.event_note(remote_note),.event_velocity(remote_velocity),.event_timbre(remote_timbre),
        .expr_valid(),.expr_ready(1'b1),.expr_mask(),.expr_gain(),.expr_bend(),.expr_vibrato(),
        .performance_valid(),.performance_ready(1'b1),.performance_opcode(),.performance_payload(),.performance_status(8'd0),
        .key_map_flat(),.current_timbre(),.effect_mode(),.panic_pulse(),
        .active_count(7'd0),.playing(1'b0),.recording(1'b0),.guide_active(1'b0),
        .overflow_sticky(1'b0),.record_count(16'd0),.score_position(16'd0),.underrun_count(32'd0),
        .record_read_index(),.record_read_valid(1'b0),.record_read_payload(80'd0));
    reg expire=0;
    wire watchdog_valid,watchdog_ready,watchdog_on;
    wire [5:0] watchdog_source; wire [6:0] watchdog_note,watchdog_velocity; wire [1:0] watchdog_timbre;
    wire [31:0] timeout_count;
    remote_note_watchdog #(.CLK_HZ(1000),.TIMEOUT_SECONDS(1)) watchdog(
        .clk(clk),.rst_n(rst_n),.heartbeat(cmd_valid && cmd_ready),.expire(expire),
        .accepted(remote_valid && remote_ready),.accepted_on(remote_on),.accepted_note(remote_note),
        .event_valid(watchdog_valid),.event_ready(watchdog_ready),.event_on(watchdog_on),
        .event_source(watchdog_source),.event_note(watchdog_note),.event_velocity(watchdog_velocity),
        .event_timbre(watchdog_timbre),.releasing(releasing),.timeout_count(timeout_count));
    reg sensor_valid=0,score_valid=0;
    reg [22:0] sensor_payload=0,score_payload=0;
    wire [3:0] arb_ready;
    wire push_valid,push_ready; wire [22:0] push_payload; wire [1:0] selected;
    note_arbiter arbiter(.clk(clk),.rst_n(rst_n),
        .in_valid({watchdog_valid,score_valid,remote_valid,sensor_valid}),.in_ready(arb_ready),
        .in_payload({watchdog_on,watchdog_source,watchdog_note,watchdog_velocity,watchdog_timbre,
            score_payload,remote_on,remote_source,remote_note,remote_velocity,remote_timbre,sensor_payload}),
        .out_valid(push_valid),.out_ready(push_ready),.out_payload(push_payload),.selected(selected));
    assign remote_ready=arb_ready[1]; assign watchdog_ready=arb_ready[3];
    wire pop_valid,pop_on; reg pop_ready=1;
    wire [5:0] pop_source;wire [6:0] pop_note,pop_velocity;wire [1:0] pop_timbre;
    wire [2:0] level;wire full,empty;
    event_fifo_v2 #(.DEPTH(4),.AWIDTH(2)) fifo(.clk(clk),.rst_n(rst_n),
        .push_valid(push_valid),.push_ready(push_ready),.push_on(push_payload[22]),
        .push_source(push_payload[21:16]),.push_note(push_payload[15:9]),.push_velocity(push_payload[8:2]),.push_timbre(push_payload[1:0]),
        .pop_valid(pop_valid),.pop_ready(pop_ready),.pop_on(pop_on),.pop_source(pop_source),
        .pop_note(pop_note),.pop_velocity(pop_velocity),.pop_timbre(pop_timbre),.level(level),.full(full),.empty(empty));

    integer command_handshakes=0, acknowledgements=0, delivered=0;
    reg [127:0] phone_held=0;
    reg [63:0] other_held=0;
    reg push_stalled=0,pop_stalled=0,remote_stalled=0,watchdog_stalled=0;
    reg [22:0] push_saved,pop_saved,remote_saved,watchdog_saved;
    reg [1:0] selected_saved;
    wire [22:0] remote_payload={remote_on,remote_source,remote_note,remote_velocity,remote_timbre};
    wire [22:0] watchdog_payload={watchdog_on,watchdog_source,watchdog_note,watchdog_velocity,watchdog_timbre};
    wire [22:0] pop_payload={pop_on,pop_source,pop_note,pop_velocity,pop_timbre};
    always @(posedge clk) begin
        if(!rst_n) begin
            phone_held=0;other_held=0;push_stalled=0;pop_stalled=0;remote_stalled=0;watchdog_stalled=0;
        end else begin
            if(push_stalled && (!push_valid || push_payload!==push_saved || selected!==selected_saved))
                $fatal(1,"locked arbiter grant/valid/payload was withdrawn under FIFO backpressure");
            if(pop_stalled && (!pop_valid || pop_payload!==pop_saved))$fatal(1,"FIFO pop changed under consumer stall");
            if(remote_stalled && (!remote_valid || remote_payload!==remote_saved))$fatal(1,"router withdrew pending NOTE");
            if(watchdog_stalled && (!watchdog_valid || watchdog_payload!==watchdog_saved))$fatal(1,"watchdog withdrew pending release");
            push_stalled=push_valid && !push_ready;push_saved=push_payload;selected_saved=selected;
            pop_stalled=pop_valid && !pop_ready;pop_saved=pop_payload;
            remote_stalled=remote_valid && !remote_ready;remote_saved=remote_payload;
            watchdog_stalled=watchdog_valid && !watchdog_ready;watchdog_saved=watchdog_payload;
            if(cmd_valid && cmd_ready)command_handshakes=command_handshakes+1;
            if(rsp_valid)begin
                if(rsp_opcode!==8'h80 || rsp_payload[15:8]!=0)$fatal(1,"unexpected command status/response");
                acknowledgements=acknowledgements+1;
            end
            if(pop_valid && pop_ready)begin
                delivered=delivered+1;
                if(pop_source==63)begin
                    if(phone_held[pop_note]===pop_on)$fatal(1,"duplicate/orphan phone transition note %0d on %b",pop_note,pop_on);
                    if(!pop_on && pop_velocity!=0)$fatal(1,"watchdog off velocity must be zero");
                    phone_held[pop_note]=pop_on;
                end else begin
                    if(!pop_on || (pop_source!=25 && pop_source!=26 && pop_source!=0 && pop_source!=1))
                        $fatal(1,"watchdog disturbed healthy sensor/score source %0d",pop_source);
                    other_held[pop_source]=1;
                end
            end
        end
    end
    function [79:0] note_command;
        input [6:0] n; input reg on;
        begin note_command={40'd0,7'd0,on,6'd0,2'd2,1'd0,(on?7'd100:7'd0),1'd0,n,8'd0}; end
    endfunction
    task send_note;
        input [7:0] sequence_id;input [6:0] n;input reg on;
        begin
            @(negedge clk);cmd_seq=sequence_id;cmd_opcode=1;cmd_payload=note_command(n,on);cmd_valid=1;
            wait(cmd_ready);@(posedge clk);@(negedge clk);cmd_valid=0;
        end
    endtask
    task other_on;
        input reg score_channel;input [5:0] source;input [6:0] note;
        begin
            @(negedge clk);
            if(score_channel)begin score_valid=1;score_payload={1'b1,source,note,7'd100,2'd2};end
            else begin sensor_valid=1;sensor_payload={1'b1,source,note,7'd100,2'd2};end
            wait(arb_ready[score_channel?2:0]);@(posedge clk);@(negedge clk);
            if(score_channel)score_valid=0;else sensor_valid=0;
        end
    endtask
    task cycles;
        input integer count;begin repeat(count)@(negedge clk);end
    endtask
    task drain_until;
        input integer wanted;integer count;
        begin
            count=0;
            while((delivered<wanted || releasing || !empty || remote_valid) && count<2000)begin @(negedge clk);count=count+1;end
            if(delivered!=wanted || releasing || !empty || remote_valid)$fatal(1,"release/drain did not finish, delivered=%0d desired=%0d",delivered,wanted);
        end
    endtask
    integer i,previous_commands;
    initial begin
        cycles(3);rst_n=1;
        send_note(1,60,1);drain_until(1);
        pop_ready=0;
        other_on(0,25,65);other_on(0,26,66);other_on(1,0,70);other_on(1,1,71);
        if(!full || level!=4)$fatal(1,"did not fill real event FIFO");
        send_note(2,0,1);cycles(5);
        if(!arbiter.locked || selected!=1 || !push_valid || push_ready)$fatal(1,"remote NOTE not locked behind full FIFO");
        expire=1;cycles(1);expire=0;
        if(!releasing)$fatal(1,"overflow expiry did not start phone release");
        // Note 0 arrives after the scan has already passed zero; it must be rescanned.
        cycles(10);
        previous_commands=command_handshakes;
        cmd_seq=3;cmd_opcode=1;cmd_payload=note_command(67,1);cmd_valid=1;
        cycles(20);
        if(cmd_ready || command_handshakes!=previous_commands || !remote_valid || !push_valid || selected!=1)
            $fatal(1,"admission gate accepted a new command or withdrew an existing grant");
        pop_ready=1;
        wait(cmd_ready);@(posedge clk);@(negedge clk);cmd_valid=0;
        drain_until(9);
        if(timeout_count!=1 || !phone_held[67] || phone_held!==(128'd1<<67) || watchdog.held!==(128'd1<<67))
            $fatal(1,"expired notes were not fully released/rescanned before reconnect");
        if(!other_held[25] || !other_held[26] || !other_held[0] || !other_held[1] || acknowledgements!=3)
            $fatal(1,"healthy groups or ACK count incorrect");
        // A duplicate request is a heartbeat but must not retrigger the note.
        for(i=0;i<6;i=i+1)begin cycles(600);send_note(3,67,1);cycles(5);end
        if(releasing || delivered!=9 || timeout_count!=1 || acknowledgements!=9)
            $fatal(1,"heartbeat or cached ACK incorrectly retriggered/expired a note");
        pop_ready=0;
        wait(releasing);wait(watchdog_valid);cycles(50);
        if(!pop_valid || pop_note!=67 || pop_on)$fatal(1,"timed release did not remain queued under consumer stall");
        pop_ready=1;drain_until(10);
        if(phone_held!=0 || watchdog.held!=0 || timeout_count!=2)$fatal(1,"timer expiry left a phone note held");
        // Reset is shared by all four protocol blocks.
        @(negedge clk);rst_n=0;cycles(3);
        if(push_valid || pop_valid || remote_valid || watchdog_valid || releasing || level!=0)
            $fatal(1,"shared reset did not clear integration state");
        $display("PASS watchdog/arbiter integration: locked grant + full FIFO + expiry; late note rescanned; healthy sources retained; heartbeat/duplicate/timer/stable/reset (%0d events)",delivered);
        $finish;
    end
    initial begin #200000;$fatal(1,"watchdog integration watchdog timeout");end
endmodule
