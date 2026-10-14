`timescale 1ns/1ps
// Exercise the production board source with the real score controller. The
// UART mux and panic inhibition match instrument_full_system's local port.
module tb_board_local_actions;
    reg clk=0;always #5 clk=!clk;
    reg rst_n=0;
    reg [1:0] keys_pressed=0;
    wire playing,guide;
    wire local_valid,local_ready;
    wire [7:0] local_action;
    reg uart_valid=0,inhibit=0,event_ready=1;
    wire command_ready,action_busy;
    wire [7:0] command_status;
    wire [7:0] command_opcode=uart_valid ? 8'h05 : 8'h04;
    wire [79:0] command_payload=uart_valid ? 80'd0 : {72'd0,local_action};
    wire command_valid=uart_valid || (local_valid && !inhibit);
    assign local_ready=rst_n && !uart_valid && command_ready && !action_busy && !inhibit;
    board_local_actions source(.clk(clk),.rst_n(rst_n),.keys_pressed(keys_pressed),
        .playing(playing),.guide(guide),.local_action_valid(local_valid),
        .local_action_ready(local_ready),.local_action(local_action));
    performance_controller #(.CLK_HZ(1000000),.SCORE_CAPACITY(64),.RECORD_CAPACITY(4)) performance(
        .clk(clk),.rst_n(rst_n),.command_valid(command_valid),.command_ready(command_ready),
        .command_opcode(command_opcode),.command_payload(command_payload),
        .command_status(command_status),.action_busy(action_busy),
        .record_valid(1'b0),.record_on(1'b0),.record_source(6'd0),.record_note(7'd0),
        .record_velocity(7'd0),.record_timbre(2'd0),.event_valid(),.event_ready(event_ready),
        .event_on(),.event_source(),.event_note(),.event_velocity(),.event_timbre(),
        .key_map_flat({25{7'd60}}),.current_timbre(2'd2),.guide_mask(),.playing(playing),
        .recording(),.guide_active(guide),.overflow_sticky(),.record_count(),
        .score_position(),.record_read_index(16'd0),.record_read_valid(),.row_payload());

    reg [7:0] expected[0:63];
    integer expected_count=0,accepted=0,cycle=0;
    integer accepted_cycle[0:63];
    reg stalled=0;
    reg [7:0] stalled_action;
    always @(posedge clk) begin
        cycle=cycle+1;
        if(!rst_n) stalled=0;
        else begin
            if(stalled && (!local_valid || local_action!==stalled_action))
                $fatal(1,"board source changed a stalled command");
            stalled=local_valid && !local_ready;stalled_action=local_action;
            if(local_valid && local_ready) begin
                if(accepted>=expected_count || local_action!==expected[accepted])
                    $fatal(1,"unexpected/duplicate board action %0d index %0d expected %0d",
                        local_action,accepted,expected[accepted]);
                if(!command_valid || command_status!=0)
                    $fatal(1,"board ready acknowledged an unaccepted controller command");
                accepted_cycle[accepted]=cycle;accepted=accepted+1;
            end
        end
    end
    always @(negedge clk) begin
        #1;
        if(rst_n && !uart_valid && action_busy!==(command_status==2))
            $fatal(1,"local busy differs from opcode-selected status");
    end
    task expect_action(input [7:0] action);
        begin expected[expected_count]=action;expected_count=expected_count+1;end
    endtask
    task set_keys(input [1:0] keys);
        begin @(negedge clk);keys_pressed=keys;end
    endtask
    task wait_count(input integer target);
        integer timeout;
        begin
            timeout=0;
            while(accepted<target && timeout<300) begin @(negedge clk);timeout=timeout+1;end
            if(accepted!=target) $fatal(1,"board action timeout %0d/%0d",accepted,target);
        end
    endtask
    task wait_idle;
        integer timeout;
        begin
            timeout=0;
            while(!performance.idle && timeout<300) begin @(negedge clk);timeout=timeout+1;end
            if(!performance.idle || performance.held!=0) $fatal(1,"score stop did not release ownership");
        end
    endtask
    task wait_held;
        integer timeout;
        begin
            timeout=0;
            while(performance.held==0 && timeout<100) begin @(negedge clk);timeout=timeout+1;end
            if(performance.held==0) $fatal(1,"score onset setup failed");
        end
    endtask
    integer base;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        // A held key and a continuously ready consumer accept one command.
        expect_action(1);set_keys(1);wait_count(1);repeat(15) @(negedge clk);
        if(accepted!=1 || !playing) $fatal(1,"held KEY0 repeated or failed to start");
        set_keys(0);expect_action(0);set_keys(1);wait_count(2);set_keys(0);wait_idle();
        expect_action(6);set_keys(2);wait_count(3);set_keys(0);
        if(playing || !guide) $fatal(1,"KEY1 did not start silent guide");

        // Inhibited requests retain their action, then guide->audio promotes
        // the next command immediately without adding a handshake bubble.
        inhibit=1;expect_action(7);expect_action(1);set_keys(1);
        repeat(20) @(negedge clk);
        if(accepted!=3 || !local_valid || local_action!=7) $fatal(1,"inhibited action lost");
        inhibit=0;wait_count(5);set_keys(0);wait_held();
        if(accepted_cycle[4]!=accepted_cycle[3]+1) $fatal(1,"guide/audio switch gained a bubble");

        // Audio->guide must wait for the old note-off under event backpressure.
        event_ready=0;expect_action(0);expect_action(6);set_keys(2);wait_count(6);
        repeat(20) @(negedge clk);
        if(accepted!=6 || !local_valid || local_action!=6 || !action_busy)
            $fatal(1,"follow-up bypassed a stalled score release");
        // Edges while a follow-up is pending keep the queued transition first.
        set_keys(3);set_keys(2);uart_valid=1;repeat(10) @(negedge clk);uart_valid=0;
        event_ready=1;wait_count(7);set_keys(0);
        if(playing || !guide || performance.held!=0) $fatal(1,"guide switch retained a score note");

        // UART priority blocks a local guide-stop without consuming it.
        uart_valid=1;expect_action(7);set_keys(2);repeat(15) @(negedge clk);
        if(accepted!=7 || !local_valid) $fatal(1,"UART contention consumed a board command");
        uart_valid=0;wait_count(8);set_keys(0);wait_idle();
        expect_action(6);set_keys(3);wait_count(9);repeat(10) @(negedge clk);
        if(accepted!=9 || playing || !guide) $fatal(1,"simultaneous keys lost KEY1 priority");
        set_keys(0);expect_action(7);set_keys(2);wait_count(10);set_keys(0);wait_idle();

        // One ready edge is enough; withdrawing ready afterward cannot repeat.
        inhibit=1;expect_action(1);set_keys(1);repeat(5) @(negedge clk);
        inhibit=0;@(posedge clk);#1;
        if(accepted!=11) $fatal(1,"one-cycle ready pulse was missed");
        @(negedge clk);inhibit=1;repeat(5) @(negedge clk);
        if(accepted!=11 || local_valid) $fatal(1,"accepted pulse remained valid");
        set_keys(0);inhibit=0;expect_action(0);set_keys(1);wait_count(12);set_keys(0);wait_idle();

        // Reset cancels both a blocked first action and a queued follow-up.
        inhibit=1;set_keys(1);repeat(3) @(negedge clk);rst_n=0;keys_pressed=0;inhibit=0;
        #1;if(local_valid) $fatal(1,"reset did not clear a blocked command");
        repeat(3) @(negedge clk);rst_n=1;repeat(5) @(negedge clk);
        if(accepted!=12) $fatal(1,"reset replayed a blocked action");
        expect_action(1);set_keys(1);wait_count(13);set_keys(0);wait_held();
        event_ready=0;expect_action(0);set_keys(2);wait_count(14);
        rst_n=0;keys_pressed=0;event_ready=1;repeat(3) @(negedge clk);rst_n=1;
        repeat(10) @(negedge clk);
        if(accepted!=14 || local_valid || playing || guide) $fatal(1,"reset replayed a mode follow-up");
        // A key held through reset produces one fresh edge after reset release.
        rst_n=0;keys_pressed=1;repeat(3) @(negedge clk);expect_action(1);rst_n=1;
        wait_count(15);repeat(10) @(negedge clk);
        if(accepted!=15) $fatal(1,"key held through reset repeated");
        set_keys(0);expect_action(0);set_keys(1);wait_count(16);set_keys(0);wait_idle();
        if(accepted!=expected_count) $fatal(1,"missing board commands");
        $display("BOARD LOCAL ACTIONS PASS %0d commands: constant/pulsed ready, busy releases, UART, inhibition, KEY1 priority, reset, no added latency",accepted);
        $finish;
    end
    initial begin #100000;$fatal(1,"board local action watchdog");end
endmodule
