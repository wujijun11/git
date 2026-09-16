`timescale 1ns/1ps
module allocator_case #(parameter N=64)(output reg finished=0);
    reg clk=0;
    always #10 clk=~clk; // Test clock only: 50 MHz, not a board-clock claim.
    reg rst_n=0, event_valid=0, event_on=0, cmd_ready=0, done_valid=0;
    reg [6:0] event_note=0, event_velocity=0;
    reg [1:0] event_timbre=0;
    reg [5:0] done_voice=0;
    wire event_ready, cmd_valid, cmd_on, done_ready;
    wire [5:0] cmd_voice;
    wire [6:0] cmd_note, cmd_velocity, active_count;
    wire [1:0] cmd_timbre;
    wire [N-1:0] active_mask, held_mask;
    wire full_pulse, ignored_pulse, done_error_pulse;
    integer k, j, cycles, accepted=0, fulls=0, ignored=0, bad_done=0;
    reg [23:0] held_cmd;
`ifdef V2_LEGACY_TEST
    wire [5:0] event_source=6'd0;
    voice_allocator_v2 #(.VOICE_COUNT(N),.ID_WIDTH(6)) dut(.*);
`else
    voice_allocator #(.VOICE_COUNT(N),.ID_WIDTH(6)) dut(.*);
`endif

    always @(posedge clk) if(rst_n) begin
        if(cmd_valid && cmd_ready) accepted=accepted+1;
        if(full_pulse) fulls=fulls+1;
        if(ignored_pulse) ignored=ignored+1;
        if(done_error_pulse) bad_done=bad_done+1;
    end
    always @(negedge clk) if(rst_n) begin
        if(active_count !== $countones(active_mask)) $fatal(1,"N=%0d count/mask mismatch",N);
        if((held_mask & ~active_mask) != 0) $fatal(1,"held slot must be active");
    end
    task send_event(input bit on_value,input integer note_value,input integer velocity_value);
        begin
            @(negedge clk);
            while(!event_ready) @(negedge clk);
            event_on=on_value; event_note=note_value;
            event_velocity=velocity_value; event_timbre=2; event_valid=1;
            @(negedge clk); event_valid=0;
        end
    endtask
    task expect_command(input bit on_value,input integer voice_value,input integer note_value,input integer velocity_value);
        begin
            cycles=0;
            while(!cmd_valid) begin
                @(negedge clk); cycles=cycles+1;
                if(cycles>N+5) $fatal(1,"command timeout N=%0d",N);
            end
            if({cmd_on,cmd_voice,cmd_note,cmd_velocity,cmd_timbre} !==
               {on_value,6'(voice_value),7'(note_value),7'(velocity_value),2'd2})
                $fatal(1,"N=%0d incorrect command on=%0d voice=%0d note=%0d",N,cmd_on,cmd_voice,cmd_note);
            held_cmd={cmd_on,cmd_voice,cmd_note,cmd_velocity,cmd_timbre};
            // Backpressure must hold every command bit and block new events.
            repeat(3) begin
                @(negedge clk);
                if(!cmd_valid || event_ready || {cmd_on,cmd_voice,cmd_note,cmd_velocity,cmd_timbre} !== held_cmd)
                    $fatal(1,"command changed under backpressure");
            end
            cmd_ready=1;
            @(negedge clk); cmd_ready=0;
            if(cmd_valid) $fatal(1,"command duplicated after acceptance");
        end
    endtask
    task wait_idle;
        begin
            cycles=0;
            while(!event_ready) begin
                @(negedge clk); cycles=cycles+1;
                if(cycles>N+5) $fatal(1,"idle timeout");
            end
            repeat(2) @(negedge clk);
        end
    endtask
    task complete_voice(input integer id);
        begin
            @(negedge clk);
            while(!done_ready) @(negedge clk);
            done_voice=id; done_valid=1;
            @(negedge clk); done_valid=0;
            repeat(2) @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        send_event(1,36,100);
        if(active_count!=0) $fatal(1,"ownership changed before cmd accepted");
        expect_command(1,0,36,100);
        if(active_count!=1) $fatal(1,"first allocation failed");
        // Retrigger the held key: reuse slot 0, do not consume a second slot.
        send_event(1,36,80); expect_command(1,0,36,80);
        if(active_count!=1) $fatal(1,"retrigger allocated twice");
        complete_voice(0); // Invalid while held.
        if(active_count!=1 || bad_done!=1) $fatal(1,"held completion guard failed");
        send_event(0,36,0); expect_command(0,0,36,0);
        if(active_count!=1 || held_mask[0]) $fatal(1,"release tail recycled too early");
        send_event(1,36,90); expect_command(1,1,36,90);
        if(active_count!=2) $fatal(1,"release tail overwritten");
        complete_voice(0);
        if(active_count!=1) $fatal(1,"release completion failed");
        complete_voice(0);
        if(active_count!=1 || bad_done!=2) $fatal(1,"duplicate completion corrupted state");
        send_event(1,36,0); expect_command(0,1,36,0); // velocity zero
        complete_voice(1);
        send_event(0,127,0); wait_idle;
        if(ignored!=1 || active_count!=0) $fatal(1,"unknown note off failed");
        for(k=0;k<N;k=k+1) begin
            send_event(1,36+k,100); expect_command(1,k,36+k,100);
        end
        if(active_count!=N || active_mask!={N{1'b1}}) $fatal(1,"full capacity failed");
        j=accepted;
        send_event(1,127,100); wait_idle;
        if(fulls!=1 || accepted!=j || active_count!=N) $fatal(1,"full handling failed");
        send_event(0,36+N-1,0); expect_command(0,N-1,36+N-1,0);
        send_event(1,127,100); wait_idle;
        if(fulls!=2 || active_count!=N) $fatal(1,"full release tail handling failed");
        complete_voice(N-1);
        send_event(1,127,110); expect_command(1,N-1,127,110);
        // Engine done and a new event arrive together: event must wait.
        send_event(0,127,0); expect_command(0,N-1,127,0);
        @(negedge clk);
        done_valid=1; done_voice=N-1;
        event_valid=1; event_on=1; event_note=126; event_velocity=100;
        #1; if(event_ready) $fatal(1,"completion priority failed");
        @(negedge clk); done_valid=0;
        @(negedge clk); event_valid=0;
        expect_command(1,N-1,126,100);
        // Reset must cancel an output command stalled by the engine.
        send_event(0,36,0);
        while(!cmd_valid) @(negedge clk);
        rst_n=0;
        @(negedge clk);
        if(cmd_valid || active_count!=0 || active_mask!=0 || event_ready) $fatal(1,"reset failed");
        rst_n=1;
        send_event(1,69,100); expect_command(1,0,69,100);
        $display("PASS allocator N=%0d: allocation/retrigger/release/full/backpressure/reset/priority",N);
        finished=1;
    end
endmodule

module tb_voice_allocator;
    wire finished4,finished64;
    allocator_case #(.N(4)) small_case(finished4);
    allocator_case #(.N(64)) full_case(finished64);
    initial begin
        wait(finished4 && finished64);
`ifdef V2_LEGACY_TEST
        $display("ALL V2 LEGACY TESTS PASSED");
`else
        $display("ALL TESTS PASSED");
`endif
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1,"watchdog timeout");
    end
endmodule
