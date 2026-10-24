`timescale 1ns/1ps
// Compare complete accepted transactions under fill/drain, wrap, stalls,
// concurrent push/pop, and reset with queued traffic. The scoreboard never
// reads implementation RAM or pointers.
module tb_event_fifo_v2_fields;
    reg clk=0; always #5 clk=~clk;
    reg rn=0,pv=0,pr=0;
    reg [22:0] payload=0;
    wire ready,valid,full,empty;
    wire [22:0] out_event;
    wire [6:0] level;
    event_fifo_v2 #(.DEPTH(64),.AWIDTH(6)) dut(
        .clk(clk),.rst_n(rn),.push_valid(pv),.push_ready(ready),
        .push_on(payload[22]),.push_source(payload[21:16]),
        .push_note(payload[15:9]),.push_velocity(payload[8:2]),.push_timbre(payload[1:0]),
        .pop_valid(valid),.pop_ready(pr),.pop_on(out_event[22]),
        .pop_source(out_event[21:16]),.pop_note(out_event[15:9]),
        .pop_velocity(out_event[8:2]),.pop_timbre(out_event[1:0]),
        .level(level),.full(full),.empty(empty));
    reg [22:0] expected[0:100000];
    integer wp=0,rp=0,occupancy=0,accepted=0,released=0;
    integer full_cycles=0,exchange_cycles=0,stall_cycles=0;
    reg held=0; reg [22:0] held_payload;
    reg [31:0] random_state=32'hb34d2917;
    function [31:0] step_random(input [31:0] x);
        reg [31:0] y;
        begin y=x^(x<<13);y=y^(y>>17);step_random=y^(y<<5);end
    endfunction
    always @(posedge clk) begin
        if(!rn) begin wp=0;rp=0;occupancy=0;held=0; end
        else begin
            if(level!==occupancy || full!==(occupancy==64) || empty!==(occupancy==0))
                $fatal(1,"FIFO accounting mismatch expected=%d actual=%d",occupancy,level);
            if(held && (!valid || out_event!==held_payload))
                $fatal(1,"FIFO changed stalled event");
            if(valid && pr) begin
                if(occupancy==0 || out_event!==expected[rp])
                    $fatal(1,"FIFO tuple changed index=%d actual=%h expected=%h",rp,out_event,expected[rp]);
                rp=rp+1;occupancy=occupancy-1;released=released+1;
            end
            if(pv && ready) begin
                expected[wp]=payload;wp=wp+1;occupancy=occupancy+1;accepted=accepted+1;
            end
            if(full)full_cycles=full_cycles+1;
            if(pv && ready && valid && pr)exchange_cycles=exchange_cycles+1;
            if(valid && !pr)stall_cycles=stall_cycles+1;
            held=valid && !pr;held_payload=out_event;
        end
    end
    task tick(input bit send,input bit receive);
        begin
            @(negedge clk);random_state=step_random(random_state);
            pv=send;pr=receive;payload=random_state[22:0];
        end
    endtask
    task reset_queue;
        begin @(negedge clk);rn=0;pv=0;pr=0;repeat(3)@(negedge clk);rn=1;end
    endtask
    initial begin
        repeat(3)@(negedge clk);rn=1;
        repeat(100)tick(1,0);
        repeat(100)tick(0,1);
        repeat(1000)tick(1,1);
        for(integer k=0;k<12000;k=k+1)tick(random_state[29],random_state[28]);
        repeat(40)tick(1,0);reset_queue();
        repeat(200)tick(1,0);reset_queue();
        for(integer k=0;k<12000;k=k+1)tick(random_state[26],random_state[25]);
        repeat(100)tick(0,1);
        @(negedge clk);pv=0;pr=0;
        if(occupancy!=0 || accepted<10000 || released<10000 || full_cycles==0 || exchange_cycles==0 || stall_cycles==0)
            $fatal(1,"coverage/count missing accepted=%d released=%d remaining=%d",accepted,released,occupancy);
        $display("EVENT FIFO FIELDS PASS accepted=%0d popped=%0d full=%0d simultaneous=%0d stalled=%0d; varied all23bits, pointer wraps, full/empty, queued reset",accepted,released,full_cycles,exchange_cycles,stall_cycles);
        $finish;
    end
endmodule
