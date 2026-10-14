`timescale 1ns/1ps
module tb_performance_controller;
    reg clk=0; always #5 clk=!clk;
    reg rst_n=0, command_valid=0;
    wire command_ready,action_busy;
    reg [7:0] command_opcode=0;
    reg [79:0] command_payload=0;
    wire [7:0] command_status;
    reg record_valid=0,record_on=0;
    reg [5:0] record_source=25;
    reg [6:0] record_note=60,record_velocity=100;
    reg [1:0] record_timbre=2;
    wire event_valid,event_on; reg event_ready=1;
    wire [5:0] event_source;
    wire [6:0] event_note,event_velocity;
    wire [1:0] event_timbre;
    reg [174:0] key_map_flat;
    reg [1:0] current_timbre=2;
    wire [24:0] guide_mask;
    wire playing,recording,guide_active,overflow_sticky;
    wire [15:0] record_count,score_position;
    reg [15:0] record_read_index=0;
    wire record_read_valid; wire [79:0] row_payload;
    performance_controller #(.CLK_HZ(10000),.SCORE_CAPACITY(64),.RECORD_CAPACITY(4)) dut(.*);

    // A non-integer clocks/ms ratio checks the same fractional timer arithmetic.
    wire fractional_ready, fractional_read_valid;
    performance_controller #(.CLK_HZ(49152),.SCORE_CAPACITY(2),.RECORD_CAPACITY(2)) fractional (
        .clk(clk),.rst_n(rst_n),.command_valid(1'b0),.command_ready(fractional_ready),
        .command_opcode(8'd0),.command_payload(80'd0),.command_status(),
        .record_valid(1'b0),.record_on(1'b0),.record_source(6'd0),.record_note(7'd0),
        .record_velocity(7'd0),.record_timbre(2'd0),.event_valid(),.event_ready(1'b1),
        .event_on(),.event_source(),.event_note(),.event_velocity(),.event_timbre(),
        .key_map_flat(key_map_flat),.current_timbre(current_timbre),.guide_mask(),
        .playing(),.recording(),.guide_active(),.overflow_sticky(),.record_count(),
        .score_position(),.record_read_index(16'd0),.record_read_valid(fractional_read_valid),.row_payload()
    );
    integer fractional_cycles=0, fractional_ticks=0;
    always @(posedge clk) begin
        if (!rst_n) begin fractional_cycles=0; fractional_ticks=0; end
        else begin
            fractional_cycles=fractional_cycles+1;
            if (fractional.tick_ms) fractional_ticks=fractional_ticks+1;
        end
    end

    reg [24:0] live_held=0;
    reg [6:0] live_note[0:24];
    reg stalled=0;
    reg [24:0] stalled_payload;
    wire [24:0] payload={event_on,event_source,event_note,event_velocity,event_timbre};
    reg [24:0] trace[0:511];
    reg [31:0] trace_ms[0:511];
    integer delivered=0;
    always @(posedge clk) begin
        if (!rst_n) begin stalled=0; live_held=0; end
        else begin
            if (stalled && (!event_valid || payload!==stalled_payload))
                $fatal(1,"performance changed a pending event under backpressure");
            stalled=event_valid && !event_ready; stalled_payload=payload;
            if (event_valid && event_ready) begin
                if (event_source>24) $fatal(1,"performance source escaped 0..24");
                if (event_on) begin
                    if (live_held[event_source]) $fatal(1,"duplicate note-on source %0d",event_source);
                    live_note[event_source]=event_note;
                end else begin
                    if (!live_held[event_source] || live_note[event_source]!==event_note || event_velocity!=0)
                        $fatal(1,"orphan or mismatched note-off source %0d note %0d",event_source,event_note);
                end
                live_held[event_source]=event_on;
                trace[delivered]=payload; trace_ms[delivered]=dut.time_ms;
                delivered=delivered+1;
            end
        end
    end
    function [79:0] score;
        input [15:0] index; input [31:0] delta;
        input [7:0] key,velocity,on;
        begin score={8'd0,on,velocity,key,delta,index}; end
    endfunction
    task command;
        input [7:0] op; input [79:0] p; input [7:0] status;
        begin
            @(negedge clk); command_opcode=op; command_payload=p; command_valid=1;
            #1;
            if (!command_ready || command_status!==status)
                $fatal(1,"command %h payload %h expected status %0d got %0d",op,p,status,command_status);
            @(posedge clk); @(negedge clk); command_valid=0;
        end
    endtask
    task wait_ms;
        input integer n; reg [31:0] start;
        begin start=dut.time_ms; while (dut.time_ms-start<n) begin @(posedge clk); #1; end end
    endtask
    task wait_delivered;
        input integer target; integer timeout;
        begin
            timeout=0;
            while (delivered<target && timeout<20000) begin @(posedge clk); #1; timeout=timeout+1; end
            if (delivered!=target) $fatal(1,"delivery timeout %0d/%0d",delivered,target);
        end
    endtask
    task wait_idle;
        integer timeout;
        begin
            timeout=0;
            while ((!dut.idle || live_held!=0) && timeout<20000) begin @(posedge clk); #1; timeout=timeout+1; end
            if (!dut.idle || live_held!=0) $fatal(1,"stop failed to drain held sources");
        end
    endtask
    task record_event;
        input reg on; input [5:0] source; input [6:0] note; input [1:0] timbre;
        begin
            @(negedge clk); record_valid=1; record_on=on; record_source=source;
            record_note=note; record_velocity=on ? 100 : 0; record_timbre=timbre;
            @(negedge clk); record_valid=0;
        end
    endtask
    task expect_event;
        input integer index; input reg on; input [5:0] source;
        input [6:0] note,velocity; input [1:0] timbre;
        begin if (trace[index]!=={on,source,note,velocity,timbre})
            $fatal(1,"wrong event[%0d]: %h",index,trace[index]); end
    endtask
    integer i,base; reg [31:0] start_ms, record_times[0:3];
    initial begin
        for (i=0;i<25;i=i+1) key_map_flat[i*7+:7]=60+i;
        repeat (4) @(negedge clk); rst_n=1;
        command(8'h05,0,3);
        command(8'h04,80'd9,1);
        command(8'h06,score(0,0,25,100,1),1);
        command(8'h06,score(0,0,0,128,1),1);
        command(8'h06,score(0,0,0,100,2),1);
        command(8'h06,{8'd1,72'd0},1);

        // Built-in score is available after reset; silent guide ignores audio ready.
        event_ready=0;
        command(8'h04,80'd6,0);
        repeat (5) @(negedge clk);
        if (playing || !guide_active || guide_mask!==25'h10 || event_valid)
            $fatal(1,"built-in silent guide did not light E4 independently: play=%b guide=%b mask=%h ev=%b mode=%d pos=%d row=%h due=%d now=%d",playing,guide_active,guide_mask,event_valid,dut.mode,score_position,dut.active_row,dut.due_ms,dut.time_ms);
        wait_ms(399);
        if (guide_mask!==25'h10 || event_valid) $fatal(1,"guide released before 400ms");
        wait_ms(2);
        if (guide_mask!=0 || event_valid) $fatal(1,"guide release timing failed");
        command(8'h04,80'd7,0);
        if (guide_mask!=0 || guide_active) $fatal(1,"guide stop failed");
        event_ready=1;

        // The uncommitted second row must never be activated.
        command(8'h06,score(0,3,24,127,1),0);
        command(8'h07,80'd2,1);
        command(8'h04,80'd1,1);
        command(8'h06,score(1,2,24,100,0),0);
        command(8'h07,80'd2,0);
        key_map_flat[24*7+:7]=96;
        base=delivered; start_ms=dut.time_ms;
        command(8'h04,80'd1,0);
        wait_delivered(base+1);
        expect_event(base,1,24,96,127,2);
        if (trace_ms[base]-start_ms!=3) $fatal(1,"first row did not wait 3ms");
        key_map_flat[24*7+:7]=97; current_timbre=1;
        wait_delivered(base+2);
        expect_event(base+1,0,24,96,0,2);
        if (trace_ms[base+1]-start_ms!=5) $fatal(1,"delta rows were not cumulative");
        wait_idle(); current_timbre=2;

        // Next upload is a fresh set: old committed rows do not satisfy new commit.
        command(8'h06,score(0,0,0,100,1),0);
        command(8'h07,80'd2,1);
        command(8'h06,score(1,100,0,0,0),0);
        command(8'h07,80'd2,0);
        event_ready=0; base=delivered;
        command(8'h04,80'd1,0);
        wait_ms(8);
        if (!event_valid || !event_on) $fatal(1,"blocked onset missing");
        command(8'h04,80'd0,0);
        command(8'h04,80'd1,2);
        wait_ms(5); event_ready=1;
        wait_delivered(base+2); wait_idle();
        expect_event(base,1,0,60,100,2); expect_event(base+1,0,0,60,0,2);

        // The full unsigned delta32 range must not become immediately due.
        command(8'h06,score(0,32'hffffffff,0,100,1),0);
        command(8'h07,80'd1,0); base=delivered;
        command(8'h04,80'd1,0); wait_ms(20);
        if (event_valid || delivered!=base || score_position!=0)
            $fatal(1,"unsigned delta32 was truncated or treated as a signed deadline");
        command(8'h04,80'd0,0); wait_idle();

        // Every physical key has an independently addressed guide bit.
        for (i=0;i<25;i=i+1) begin
            key_map_flat[i*7+:7]=60+i;
            command(8'h06,score(i,0,i,100,1),0);
        end
        command(8'h06,score(25,20,0,0,0),0);
        command(8'h07,80'd26,0);
        event_ready=0; command(8'h04,80'd6,0);
        repeat (70) @(negedge clk);
        if (guide_mask!==25'h1ffffff || event_valid || playing)
            $fatal(1,"25-key independent LED guide failed");
        command(8'h04,80'd7,0); event_ready=1;
        base=delivered; command(8'h04,80'd1,0);
        wait_delivered(base+50); wait_idle();
        for (i=0;i<25;i=i+1) begin
            expect_event(base+i,1,i,60+i,100,2);
            expect_event(base+25+i,0,i,60+i,0,2);
        end

        // Passive recorder produces 82-compatible rows, and replay remaps sources.
        base=delivered;
        command(8'h04,80'd2,0);
        record_times[0]=dut.time_ms-dut.last_record_ms;
        record_event(1,25,60,2);
        wait_ms(2); record_times[1]=dut.time_ms-dut.last_record_ms;
        record_event(1,49,84,1);
        wait_ms(3); record_times[2]=dut.time_ms-dut.last_record_ms;
        record_event(0,25,60,2);
        wait_ms(1); record_times[3]=dut.time_ms-dut.last_record_ms;
        record_event(0,49,84,1);
        command(8'h04,80'd3,0);
        if (record_count!=4 || recording || overflow_sticky || delivered!=base)
            $fatal(1,"passive recorder affected audio or lost rows");
        for (i=0;i<4;i=i+1) begin
            @(negedge clk); record_read_index=i; @(posedge clk); #1;
            if (!record_read_valid || row_payload[15:0]!=i || row_payload[47:16]!=record_times[i])
                $fatal(1,"record readback index/delta wrong row %0d",i);
            if (row_payload[55:48]!=(i%2 ? 49 : 25) || row_payload[63:56]!=(i%2 ? 84 : 60) ||
                row_payload[71:64]!=(i<2 ? 100 : 0) ||
                row_payload[79:72]!={5'd0,(i%2 ? 2'd1 : 2'd2),(i<2)})
                $fatal(1,"record readback field packing wrong row %0d payload %h",i,row_payload);
        end
        @(negedge clk); record_read_index=4; @(posedge clk); #1;
        if (record_read_valid || row_payload!=0) $fatal(1,"out-of-range read exposed RAM");
        command(8'h04,80'd8,0);
        wait_delivered(base+4); wait_idle();
        expect_event(base,1,0,60,100,2); expect_event(base+1,1,24,84,100,1);
        expect_event(base+2,0,0,60,0,2); expect_event(base+3,0,24,84,0,1);

        command(8'h04,80'd2,0);
        for (i=0;i<5;i=i+1) record_event(i%2==0,25,60,2);
        if (recording || record_count!=4 || !overflow_sticky)
            $fatal(1,"record overflow did not stop and report without overwriting");
        command(8'h04,80'd4,0);
        if (record_count!=0 || overflow_sticky) $fatal(1,"record clear failed");
        command(8'h04,80'd2,0); record_event(1,63,72,1); command(8'h04,80'd3,0);
        command(8'h04,80'd8,1);
        command(8'h04,80'd2,0); command(8'h04,80'd5,0); wait_idle();
        if (recording) $fatal(1,"panic did not stop recording");

        // Panic releases an audible note; reset also clears held output and storage metadata.
        command(8'h07,80'h10000,0);
        base=delivered; command(8'h04,80'd1,0); wait_delivered(base+1);
        command(8'h04,80'd5,0); wait_delivered(base+2); wait_idle();
        event_ready=0; command(8'h04,80'd1,0); repeat (5) @(negedge clk);
        rst_n=0; repeat (3) @(negedge clk);
        if (event_valid || playing || recording || guide_active || guide_mask!=0 || record_count!=0)
            $fatal(1,"reset left performance state active");
        rst_n=1;
        // Timer must produce exactly floor(cycles*1000/49152) ticks, no truncated divider drift.
        repeat (49152) @(negedge clk);
        if (fractional_ticks != (64'd1*fractional_cycles*1000)/49152)
            $fatal(1,"fractional 1ms timer drift %0d ticks in %0d clocks",fractional_ticks,fractional_cycles);
        $display("PASS performance: %0d ordered events; timer, 25-key guide, commit, map, stalls, stop/panic, recorder/readback/replay/overflow/reset",delivered);
        $finish;
    end
    initial begin #5000000; $fatal(1,"performance simulation watchdog"); end
endmodule
