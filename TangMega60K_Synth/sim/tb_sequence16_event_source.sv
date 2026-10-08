`timescale 1ns/1ps
module tb_sequence16_event_source;
    localparam integer CLK_HZ=49152000, NOTE_MS=1, GAP_MS=1;
    localparam integer NOTE_CYCLES=49152, GAP_CYCLES=49152;
    reg clk=0, rst_n=0, start=0, stop=0, fault=0, block_ready=0, foreign_active=0;
    always #5 clk=~clk;
    reg [31:0] random_state=32'h49abcd12;
    wire valid,ready,on_value,busy,holding,done,error,start_ready;
    wire [5:0] source;
    wire [6:0] note,velocity;
    wire [1:0] timbre;
    reg [15:0] held=0,alive=0;
    integer tail=0,tail_note=0,cooldown=0;
    wire [6:0] active_count=foreign_active ? 7'd1 : $countones(alive);
    assign ready=!block_ready && cooldown==0 && random_state[2:0]!=0;
    sequence16_event_source #(.CLK_HZ(CLK_HZ),.NOTE_MS(NOTE_MS),.GAP_MS(GAP_MS)) dut(
        .clk(clk),.rst_n(rst_n),.start(start),.stop(stop),.active_count(active_count),
        .allocation_error(fault),.start_ready(start_ready),.busy(busy),.holding(holding),
        .released_pulse(done),.error(error),.event_valid(valid),.event_ready(ready),
        .event_on(on_value),.event_source(source),.event_note(note),
        .event_velocity(velocity),.event_timbre(timbre));
    // Elaborate production defaults too: the unscaled multiplication would
    // exceed 32 bits for the 400 ms hold and silently shorten its duration.
    sequence16_event_source production_constants(
        .clk(clk),.rst_n(1'b0),.start(1'b0),.stop(1'b0),.active_count(7'd0),
        .allocation_error(1'b0),.event_ready(1'b1));
    integer cycles=0,ons=0,offs=0,completions=0,expected_note=60,id=0;
    integer on_cycle=0,zero_cycle=0,stalled_cycles=0,scenarios=0,min_hold=2147483647,min_gap=2147483647;
    reg abort_expected=0,stalled=0,had_release=0;
    reg [22:0] payload;
    always @(posedge clk) begin
        random_state<={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
        cycles=cycles+1;
        if(!rst_n) begin
            held<=0; alive<=0; tail<=0; cooldown<=0;
            ons=0; offs=0; completions=0; expected_note=60;
            stalled=0; had_release=0; on_cycle=0; zero_cycle=cycles;
        end else begin
            if(stalled && (!valid || {on_value,source,note,velocity,timbre}!==payload))
                $fatal(1,"valid/payload changed during backpressure");
            stalled=valid && !ready;
            payload={on_value,source,note,velocity,timbre};
            if(stalled) stalled_cycles=stalled_cycles+1;
            if(cooldown>0) cooldown<=cooldown-1;
            if(tail>0) begin
                tail<=tail-1;
                if(tail==1) begin alive<=0; zero_cycle=cycles; had_release=1; end
            end
            if($countones(alive)>1 || $countones(held)>1) $fatal(1,"overlapping voices");
            if(valid && ready) begin
                if(source!=63 || velocity!=100 || timbre!=0 || note<60 || note>75)
                    $fatal(1,"incorrect fixed payload");
                cooldown<=3;
                id=note-60;
                if(on_value) begin
                    if(alive!=0 || held!=0 || ons!=offs || note!=expected_note)
                        $fatal(1,"ON overlap/order: note=%0d expected=%0d",note,expected_note);
                    if(had_release) begin
                        if(cycles-zero_cycle<GAP_CYCLES) $fatal(1,"silence gap too short");
                        if(cycles-zero_cycle<min_gap) min_gap=cycles-zero_cycle;
                    end
                    held<=16'b1<<id; alive<=16'b1<<id;
                    ons=ons+1; on_cycle=cycles;
                    expected_note=(expected_note==75) ? 60 : expected_note+1;
                end else begin
                    if(held!=(16'b1<<id) || offs!=ons-1) $fatal(1,"OFF duplicate/wrong note");
                    if(!abort_expected) begin
                        if(cycles-on_cycle<NOTE_CYCLES) $fatal(1,"held duration too short");
                        if(cycles-on_cycle<min_hold) min_hold=cycles-on_cycle;
                    end
                    held<=0; tail<=19+id; tail_note<=id; offs=offs+1;
                end
            end
            if(done) begin
                if(held!=0 || alive!=0 || ons!=offs || busy) $fatal(1,"completion before release");
                completions=completions+1;
            end
        end
    end
    task reset_all;
        begin
            @(negedge clk); rst_n=0; start=0; stop=0; fault=0; block_ready=0; foreign_active=0; abort_expected=0;
            repeat(3) @(negedge clk); rst_n=1; repeat(3) @(negedge clk);
            if(busy || valid || holding) $fatal(1,"auto-started after reset");
        end
    endtask
    task launch;
        begin
            @(negedge clk); while(!start_ready) @(negedge clk); start=1;
            @(negedge clk); start=0;
        end
    endtask
    task finish_check;
        input expect_error;
        begin
            wait(done); repeat(5) @(negedge clk);
            if(completions!=1 || busy || valid || error!==expect_error || ons!=offs)
                $fatal(1,"stop/fault final status error=%0d",error);
            scenarios=scenarios+1;
        end
    endtask
    initial begin
        if(production_constants.NOTE_CYCLES!=19660800 || production_constants.GAP_CYCLES!=4915200)
            $fatal(1,"production timing constant overflow");
        // Thirty-four notes prove all 16 pitches and wraparound twice, with
        // engine acceptance delays, random backpressure, and release tails.
        reset_all(); launch();
        repeat(4) begin @(negedge clk); start=1; @(negedge clk); start=0; end
        wait(ons==34 && holding); @(negedge clk); abort_expected=1; stop=1;
        @(negedge clk); stop=0; finish_check(0);
        if(ons!=34) $fatal(1,"repeated start or wrong loop count");

        // Stop cannot retract a previously offered, stalled ON transaction.
        reset_all(); launch(); block_ready=1; stop=1; start=1; abort_expected=1;
        repeat(11) @(negedge clk);
        if(ons!=0 || !valid || !on_value) $fatal(1,"stalled ON cancelled");
        stop=0; block_ready=0; finish_check(0);
        repeat(100) @(negedge clk);
        if(busy || ons!=1 || offs!=1) $fatal(1,"held start automatically restarted");

        // Stop during a held note is urgent; OFF remains stable while blocked.
        reset_all(); launch(); wait(holding); @(negedge clk); abort_expected=1; stop=1;
        @(negedge clk); block_ready=1; stop=0;
        repeat(17) @(negedge clk);
        if(!valid || on_value || offs!=0) $fatal(1,"stalled OFF missing");
        block_ready=0; finish_check(0);

        // Stop during actual silence must complete without starting another note.
        reset_all(); launch(); wait(dut.state==6); @(negedge clk); stop=1; abort_expected=1;
        @(negedge clk); stop=0; finish_check(0);
        if(ons!=1 || offs!=1) $fatal(1,"stop during gap started another note");

        // Allocation faults release accepted notes then latch the error.
        reset_all(); launch(); wait(holding); @(negedge clk); fault=1; abort_expected=1;
        @(negedge clk); fault=0; finish_check(1);
        reset_all(); launch(); block_ready=1; fault=1; abort_expected=1;
        repeat(7) @(negedge clk); fault=0; block_ready=0; finish_check(1);

        // Whole-system reset clears stalled ON, stalled OFF and the release tail.
        reset_all(); launch(); block_ready=1; repeat(4) @(negedge clk); reset_all();
        launch(); wait(holding); @(negedge clk); stop=1; abort_expected=1;
        @(negedge clk); block_ready=1; reset_all();
        launch(); wait(holding); @(negedge clk); stop=1; abort_expected=1;
        wait(dut.state==5); reset_all();
        if(busy || valid || active_count!=0) $fatal(1,"reset failed to silence");

        // Simultaneous start/stop and nonempty-allocator starts cannot run.
        @(negedge clk); start=1; stop=1; repeat(5) @(negedge clk);
        if(busy || valid) $fatal(1,"start won over stop");
        reset_all(); foreign_active=1; @(negedge clk); start=1;
        repeat(3) @(negedge clk);
        if(busy || valid || !error || start_ready) $fatal(1,"nonempty start accepted");
        $display("SEQUENCE16 SOURCE PASSED ordered_notes=34 max_voices=1 min_hold_cycles=%0d min_silent_gap_cycles=%0d configured_hold=%0d configured_gap=%0d scenarios=%0d stalled_cycles=%0d reset_and_fault=covered",min_hold,min_gap,NOTE_CYCLES,GAP_CYCLES,scenarios,stalled_cycles);
        $finish;
    end
    initial begin
        #100000000; $fatal(1,"timeout state=%0d ons=%0d offs=%0d active=%0d scenarios=%0d",dut.state,ons,offs,active_count,scenarios);
    end
endmodule
