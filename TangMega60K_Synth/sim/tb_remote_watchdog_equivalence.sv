`timescale 1ns/1ps
// The reference is a frozen, source-hashed copy of the repaired 2026-10-14
// design. Transaction accounting below is separate from either RTL's scan
// implementation; every clock compares external behavior and note ownership.
module tb_remote_watchdog_equivalence;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,heartbeat=0,expire=0,accepted=0,accepted_on=0,event_ready=0;
    reg [6:0] accepted_note=0;
    wire dv,don,dr,rv,ron,rr;
    wire [5:0] ds,rs;
    wire [6:0] dn,dvel,rn,rvel;
    wire [1:0] dt,rt;
    wire [31:0] dc,rc;
    remote_note_watchdog #(.CLK_HZ(37),.TIMEOUT_SECONDS(1)) dut (
        .clk(clk),
`ifndef WATCHDOG_BASELINE
        .keepalive_required(1'b0),
`endif
        .rst_n(rst_n),.heartbeat(heartbeat),.expire(expire),
        .accepted(accepted),.accepted_on(accepted_on),.accepted_note(accepted_note),
        .event_valid(dv),.event_ready(event_ready),.event_on(don),.event_source(ds),
        .event_note(dn),.event_velocity(dvel),.event_timbre(dt),.releasing(dr),.timeout_count(dc));
    remote_note_watchdog_reference #(.CLK_HZ(37),.TIMEOUT_SECONDS(1)) reference (
        .clk(clk),.rst_n(rst_n),.heartbeat(heartbeat),.expire(expire),
        .accepted(accepted),.accepted_on(accepted_on),.accepted_note(accepted_note),
        .event_valid(rv),.event_ready(event_ready),.event_on(ron),.event_source(rs),
        .event_note(rn),.event_velocity(rvel),.event_timbre(rt),.releasing(rr),.timeout_count(rc));
    wire [56:0] dut_outputs={dv,don,ds,dn,dvel,dt,dr,dc};
    wire [56:0] ref_outputs={rv,ron,rs,rn,rvel,rt,rr,rc};
    wire [22:0] dut_payload={don,ds,dn,dvel,dt};

    reg [127:0] ledger=0,on_seen=0,off_seen=0,release_seen=0,same_note_ack_seen=0;
    reg stalled=0;
    reg [22:0] stalled_payload=0;
    reg pre_releasing;
    reg [31:0] pre_count;
    integer cycles=0,accept_cycles=0,heartbeat_cycles=0,expire_cycles=0;
    integer stall_cycles=0,release_acks=0,first_on_expire_edges=0,last_off_expire_edges=0;
    integer accepted_ack_edges=0,reset_edges=0;
    reg [127:0] ledger_before;
    bit oracle_negative;
    initial oracle_negative=$test$plusargs("ORACLE_NEGATIVE");

    always @(posedge clk) begin
        cycles=cycles+1;
        pre_releasing=dr;
        pre_count=dc;
        ledger_before=ledger;
        if(!rst_n) begin
            ledger=0;
            stalled=0;
            reset_edges=reset_edges+1;
        end else begin
            if(stalled && (!dv || dut_payload!==stalled_payload))
                $fatal(1,"stalled release changed cycle=%0d",cycles);
            stalled=dv && !event_ready;
            stalled_payload=dut_payload;
            if(heartbeat)heartbeat_cycles=heartbeat_cycles+1;
            if(expire)expire_cycles=expire_cycles+1;
            if(dv && !event_ready)stall_cycles=stall_cycles+1;
            if(accepted) begin
                accept_cycles=accept_cycles+1;
                if(accepted_on)on_seen[accepted_note]=1;
                else off_seen[accepted_note]=1;
                if(expire && !dr && ledger_before==0 && accepted_on)
                    first_on_expire_edges=first_on_expire_edges+1;
                ledger[accepted_note]=accepted_on;
                if(expire && !dr && !accepted_on && ledger_before!=0 && ledger==0)
                    last_off_expire_edges=last_off_expire_edges+1;
            end
            // An acknowledged forced NoteOff commits after an accepted command,
            // including an accepted NoteOn for the same note on this edge.
            if(dv && event_ready) begin
                if(!dr || don || ds!=63 || dvel!=0 || dt!=0)
                    $fatal(1,"invalid forced release cycle=%0d",cycles);
                release_acks=release_acks+1;
                release_seen[dn]=1;
                ledger[dn]=0;
                if(accepted)begin
                    accepted_ack_edges=accepted_ack_edges+1;
                    if(accepted_note==dn && accepted_on)same_note_ack_seen[dn]=1;
                end
            end
        end
        #1;
        // A deliberately altered comparison at clock 10 proves that the
        // runner rejects $fatal even when this ModelSim returns exit code zero.
        if(dut_outputs!==(ref_outputs ^ ((oracle_negative && cycles==10) ? 57'd1 : 57'd0)))
            $fatal(1,"output mismatch cycle=%0d dut=%h reference=%h",cycles,dut_outputs,ref_outputs);
        if(dut.held!==reference.held)
            $fatal(1,"ownership mismatch cycle=%0d dut=%h reference=%h",cycles,dut.held,reference.held);
        if(dut.held!==ledger)
            $fatal(1,"transaction ledger mismatch cycle=%0d dut=%h ledger=%h",cycles,dut.held,ledger);
        if(rst_n && dc!==pre_count && (pre_releasing || !dr || dc!==pre_count+32'd1))
            $fatal(1,"timeout counter changed outside new release cycle=%0d",cycles);
    end

    task step(input bit a,input bit v,input integer n,input bit h,input bit e,input bit ready);
        begin
            @(negedge clk);
            accepted=a;accepted_on=v;accepted_note=n;heartbeat=h;expire=e;event_ready=ready;
            @(posedge clk);#2;
        end
    endtask
    task reset_case;
        begin
            @(negedge clk);
            rst_n=0;accepted=0;accepted_on=0;accepted_note=0;heartbeat=0;expire=0;event_ready=0;
            repeat(3)@(negedge clk);
            rst_n=1;
            @(posedge clk);#2;
        end
    endtask
    task wait_note(input integer wanted);
        integer k;
        begin
            k=0;
            while(!dv && k<150)begin step(0,0,0,0,0,0);k=k+1;end
            if(!dv || dn!=wanted)$fatal(1,"expected release note=%0d got=%0d valid=%b",wanted,dn,dv);
        end
    endtask
    task drain;
        integer k;
        begin
            k=0;
            while((dr || dv) && k<600)begin step(0,0,0,0,0,1);k=k+1;end
            if(dr || dv || ledger!=0)$fatal(1,"release did not drain");
        end
    endtask

    reg [31:0] rng;
    function automatic [31:0] next_random(input [31:0] previous);
        reg [31:0] value;
        begin
            value=previous^(previous<<13);
            value=value^(value>>17);
            next_random=value^(value<<5);
        end
    endfunction
    integer n,k,phase,random_cycles,seed;
    initial begin
        if(!$value$plusargs("RANDOM_CYCLES=%d",random_cycles))random_cycles=20000;
        if(!$value$plusargs("SEED=%d",seed))seed=734921;
        if(random_cycles<1000 || random_cycles>1000000)$fatal(1,"invalid RANDOM_CYCLES");
        reset_case();
        step(1,1,127,1,1,0);
        if(!dr || dc!=1)$fatal(1,"first accepted On+expire did not own expiry");
        wait_note(127);
        repeat(17)step(0,0,0,0,0,0);
        step(0,0,0,0,0,1);drain();
        reset_case();
        step(1,1,31,1,0,0);
        step(1,0,31,1,1,0);
        if(dr || dc!=0)$fatal(1,"last accepted Off+expire started empty release");

        // Fill and force-release every MIDI note, including both boundaries.
        // For all 128 notes reaccept the same On on its release acknowledgement.
        reset_case();
        for(n=0;n<128;n=n+1)step(1,1,n,1,0,0);
        for(n=0;n<128;n=n+1)step(1,0,n,1,0,0);
        for(n=0;n<128;n=n+1)step(1,1,n,1,0,0);
        step(0,0,0,0,1,0);
        for(n=0;n<128;n=n+1)begin
            wait_note(n);
            repeat(2)step(0,0,0,0,0,0);
            step(1,1,n,1,0,1);
            if(dut.held[n])$fatal(1,"acknowledgement did not win accepted On note=%0d",n);
        end
        // On at the end of a scan keeps release active and restarts at zero.
        step(1,1,7,0,0,1);
        wait_note(7);step(0,0,0,0,0,1);drain();

        // Add a lower-numbered note after its position has already been scanned.
        reset_case();step(1,1,90,1,1,0);wait_note(90);
        step(1,1,3,1,0,0);
        repeat(11)step(0,0,0,0,0,0);
        step(1,0,90,0,0,1);
        wait_note(3);step(0,0,0,0,0,1);drain();

        // Natural timeout, heartbeat suppression at the expiry threshold, and
        // timer restart after heartbeat, independent of explicit expiry.
        reset_case();step(1,1,64,1,0,1);
        repeat(36)step(0,0,0,0,0,1);
        step(0,0,0,1,0,1);
        if(dr)$fatal(1,"heartbeat failed to suppress timeout");
        repeat(38)step(0,0,0,0,0,0);
        if(!dr)$fatal(1,"natural timeout missing");
        wait_note(64);step(0,0,0,0,0,1);drain();

        for(phase=0;phase<5;phase=phase+1)begin
            reset_case();rng=seed^(32'h9e3779b9*(phase+1));
            if(rng==0)rng=1;
            for(k=0;k<random_cycles/5;k=k+1)begin
                rng=next_random(rng);
                // Directed collisions during random traffic strengthen the
                // protocol test without deriving a prediction from DUT logic.
                if(dv && rng[5:3]==0)
                    step(1,rng[2],dn,rng[6],rng[7:6]==0,rng[8]);
                else
                    step(rng[2:0]!=0,rng[3],rng[16:10],rng[9:8]==0,rng[7:4]==0,rng[17:16]!=0);
            end
            step(0,0,0,0,1,1);drain();
        end
        if(on_seen!=={128{1'b1}} || off_seen!=={128{1'b1}} ||
           release_seen!=={128{1'b1}} || same_note_ack_seen!=={128{1'b1}})
            $fatal(1,"missing all-note coverage");
        if(first_on_expire_edges<1 || last_off_expire_edges<1 || stall_cycles<128 ||
           accepted_ack_edges<128 || heartbeat_cycles<128 || expire_cycles<5)
            $fatal(1,"missing protocol coverage");
        $display("WATCHDOG EQUIVALENCE PASS cycles=%0d random_cycles=%0d seed=%0d notes=128 same_note_ack=128 accepted=%0d release_acks=%0d stalls=%0d heartbeats=%0d expiry=%0d resets=%0d",cycles,random_cycles,seed,accept_cycles,release_acks,stall_cycles,heartbeat_cycles,expire_cycles,reset_edges);
        $finish;
    end
    initial begin #20000000;$fatal(1,"equivalence simulation timeout");end
endmodule
