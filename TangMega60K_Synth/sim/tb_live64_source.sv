`timescale 1ns/1ps
module tb_live64_source;
    reg test_passed=0;
    reg clk=0,rst_n=0,start=0,stop=0,fault=0,block_ready=0,foreign_active=0;
    always #5 clk=~clk;
    reg [31:0] random_state=32'h49abcd12;
    wire valid,ready,on_value,busy,holding,done,error,start_ready;
    wire [5:0] source;
    wire [6:0] note,velocity;
    wire [1:0] timbre;
    reg [63:0] held=0,alive=0;
    integer tails[0:63];
    wire [6:0] active_count=foreign_active ? 7'd1 : $countones(alive);
    assign ready=!block_ready && (random_state[2:0]!=0);
    live64_event_source dut(.clk(clk),.rst_n(rst_n),.start(start),.stop(stop),
        .active_count(active_count),.allocation_error(fault),.start_ready(start_ready),
        .busy(busy),.holding(holding),.released_pulse(done),.error(error),
        .event_valid(valid),.event_ready(ready),.event_on(on_value),
        .event_source(source),.event_note(note),.event_velocity(velocity),.event_timbre(timbre));
    integer ons=0,offs=0,completions=0,i,id,scenarios=0,stalled_cycles=0;
    reg stalled=0;
    reg [22:0] payload;
    always @(posedge clk) begin
        random_state<={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
        if(!rst_n) begin
            held=0; alive=0; ons=0; offs=0; completions=0; stalled=0;
            for(i=0;i<64;i=i+1) tails[i]=0;
        end else begin
            if(stalled && (!valid || {on_value,source,note,velocity,timbre}!==payload))
                $fatal(1,"event changed while stalled");
            stalled=valid && !ready;
            payload={on_value,source,note,velocity,timbre};
            if(stalled) stalled_cycles=stalled_cycles+1;
            for(i=0;i<64;i=i+1) if(tails[i]>0) begin
                tails[i]=tails[i]-1;
                if(tails[i]==0) alive[i]=0;
            end
            if(valid && ready) begin
                if(source!=63 || velocity!=100 || timbre!=0 || note<36 || note>99)
                    $fatal(1,"incorrect event payload");
                id=note-36;
                if(on_value) begin
                    if(id!=ons || held[id] || offs!=0) $fatal(1,"duplicate/lost/out-of-order on");
                    held[id]=1; alive[id]=1; ons=ons+1;
                end else begin
                    if(id!=offs || !held[id]) $fatal(1,"duplicate/lost/out-of-order off");
                    held[id]=0; tails[id]=19+id; offs=offs+1;
                end
            end
            if(holding && (ons!=64 || offs!=0 || active_count!=64)) $fatal(1,"early holding");
            if(done) begin
                if(ons!=offs || held!=0 || alive!=0 || busy) $fatal(1,"early/incomplete release");
                completions=completions+1;
            end
        end
    end
    task reset_all;
        begin
            @(negedge clk); rst_n=0; start=0; stop=0; fault=0; block_ready=0; foreign_active=0;
            repeat(3) @(negedge clk);
            rst_n=1; repeat(3) @(negedge clk);
        end
    endtask
    task launch;
        begin
            @(negedge clk); while(!start_ready) @(negedge clk); start=1;
            @(negedge clk); start=0;
        end
    endtask
    task finish_check;
        begin
            wait(done); repeat(5) @(negedge clk);
            if(completions!=1 || busy || valid || error || ons!=offs) $fatal(1,"completion count/status");
            scenarios=scenarios+1;
        end
    endtask
    integer cut,n_before;
    initial begin
        // Every possible stop position, including a pending but stalled on.
        for(cut=0;cut<64;cut=cut+1) begin
            reset_all(); launch();
            if(cut>0) begin wait(ons==cut); @(negedge clk); end
            block_ready=1; stop=1; start=1;
            n_before=ons;
            repeat(7) @(negedge clk);
            if(ons!=n_before || !valid || !on_value) $fatal(1,"stop cancelled pending on");
            stop=0; start=0; block_ready=0;
            finish_check();
            if(ons!=cut+1) $fatal(1,"unexpected accepted-on count cut=%0d on=%0d",cut,ons);
        end
        reset_all(); launch();
        // Repeated start during loading must not restart the sequence.
        repeat(4) begin @(negedge clk); start=1; @(negedge clk); start=0; end
        wait(holding); @(negedge clk); start=1;
        repeat(80) @(negedge clk);
        if(ons!=64 || valid) $fatal(1,"repeated start generated events");
        stop=1; @(negedge clk); stop=0;
        wait(valid && !on_value); @(negedge clk); block_ready=1;
        repeat(20) @(negedge clk); block_ready=0;
        finish_check();
        repeat(100) @(negedge clk);
        if(busy || ons!=64) $fatal(1,"held start auto-restarted");
        // Reset safely withdraws a blocked transaction only with whole-system reset.
        reset_all(); launch(); @(negedge clk); block_ready=1;
        repeat(5) @(negedge clk); reset_all();
        if(valid || busy || active_count!=0) $fatal(1,"reset pending on");
        launch(); wait(holding); @(negedge clk); stop=1;
        wait(valid && !on_value); @(negedge clk); block_ready=1;
        reset_all(); if(valid || busy) $fatal(1,"reset pending off");
        launch(); wait(holding); @(negedge clk); stop=1;
        wait(!valid && busy); reset_all(); if(busy) $fatal(1,"reset drain");
        // Simultaneous start/stop must not start a run.
        @(negedge clk); start=1; stop=1; repeat(5) @(negedge clk);
        if(busy || valid) $fatal(1,"start beat stop");
        reset_all(); foreign_active=1;
        @(negedge clk); start=1; repeat(3) @(negedge clk);
        if(busy || valid || !error || start_ready) $fatal(1,"nonempty start accepted");
        reset_all(); launch(); wait(holding); @(negedge clk); fault=1;
        @(negedge clk); fault=0; wait(done); repeat(3) @(negedge clk);
        if(!error || ons!=offs) $fatal(1,"fault did not cleanly abort");
        $display("LIVE64 SOURCE PASSED stop_positions=64 full_run=1 scenarios=%0d stalled_cycles=%0d reset_and_fault=covered",scenarios,stalled_cycles);
        test_passed=1; $finish;
    end
    initial begin #10000000; $fatal(1,"source timeout cut=%0d on=%0d off=%0d state=%0d active=%0d error=%0d scenarios=%0d",cut,ons,offs,dut.state,active_count,error,scenarios); end
endmodule
