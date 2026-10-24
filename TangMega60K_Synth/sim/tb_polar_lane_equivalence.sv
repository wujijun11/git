`timescale 1ns/1ps
// Semantic equivalence only. The independent Gowin STA must verify real
// half-cycle setup/hold on the actual PLL clock before this RTL can be selected.
module tb_polar_lane_equivalence;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,start=0,active=0;
    reg [5:0] voice=0;
    reg [19:0] age=0;
    reg [31:0] base_ftw=20000000,fundamental_ftw=20000000;
    wire nv0,nv1,ov0,ov1;
    wire signed [31:0] nl0,nr0,nl1,nr1,ol0,or0,ol1,or1;
    localparam ROM="candidate/rtl/audio/rom/";
    polar_lane #(.LANE(0),.ROM_DIR(ROM)) n0(clk,rst_n,start,voice,active,age,fundamental_ftw,base_ftw,nv0,nl0,nr0);
    polar_lane #(.LANE(1),.ROM_DIR(ROM)) n1(clk,rst_n,start,voice,active,age,fundamental_ftw,base_ftw,nv1,nl1,nr1);
    polar_lane_reference #(.LANE(0),.ROM_DIR(ROM)) o0(clk,rst_n,start,voice,active,age,fundamental_ftw,base_ftw,ov0,ol0,or0);
    polar_lane_reference #(.LANE(1),.ROM_DIR(ROM)) o1(clk,rst_n,start,voice,active,age,fundamental_ftw,base_ftw,ov1,ol1,or1);
    integer cycles=0,writes0=0,writes1=0,read_write_same0=0,read_write_same1=0;
    integer starts=0,outputs=0,nonzero_outputs=0,age_zero=0,inactive_starts=0,bent_starts=0;
    integer boundary0=0,boundary1=0,terminal0=0,terminal1=0,clamp_low0=0,clamp_high0=0;
    integer reset_before_fall=0,reset_after_fall=0,all_row_compares=0;
    integer read_state_compares=0,sensitive_collision0=0,sensitive_collision1=0;
    reg [63:0] voices_seen=0;
    reg [3:0] regions_seen=0;
    reg oracle_negative=0;
    reg write0_before,write1_before;
    reg collision0_before,collision1_before;
    reg [7:0] addr0_before,addr1_before;

    task compare_state;
        integer row;
        begin
            // Check read-before-write semantics at the first observable stage.
            // Audio alone can hide a collision when age==0 resets old state.
            if({n0.s0,n0.s1,n1.s0,n1.s1} !== {o0.s0,o0.s1,o1.s0,o1.s1})
                $fatal(1,"polar RAM read-state mismatch cycle=%0d age=%0d sameaddr=%0d/%0d",cycles,age,
                    collision0_before,collision1_before);
            read_state_compares=read_state_compares+1;
            if({nv0,nl0,nr0,nv1,nl1,nr1} !==
               ({ov0,ol0,or0,ov1,ol1,or1} ^ ((oracle_negative && cycles==20) ? 130'd1 : 130'd0)))
                $fatal(1,"polar output mismatch cycle=%0d",cycles);
            if({n0.v,n0.issuing,n0.issue_pair,n0.issue_voice,n0.sumL,n0.sumR,
                n1.v,n1.issuing,n1.issue_pair,n1.issue_voice,n1.sumL,n1.sumR} !==
               {o0.v,o0.issuing,o0.issue_pair,o0.issue_voice,o0.sumL,o0.sumR,
                o1.v,o1.issuing,o1.issue_pair,o1.issue_voice,o1.sumL,o1.sumR})
                $fatal(1,"polar metadata mismatch cycle=%0d",cycles);
            if(write0_before && n0.states[addr0_before] !== o0.states[addr0_before])
                $fatal(1,"lane0 RAM write mismatch cycle=%0d address=%0d",cycles,addr0_before);
            if(write1_before && n1.states[addr1_before] !== o1.states[addr1_before])
                $fatal(1,"lane1 RAM write mismatch cycle=%0d address=%0d",cycles,addr1_before);
            // Include untouched/uninitialized rows with case inequality; sparse
            // writes must not silently corrupt neighboring voice/partial state.
            if(cycles%64==0)begin
                for(row=0;row<256;row=row+1)begin
                    if(n0.states[row] !== o0.states[row] || n1.states[row] !== o1.states[row])
                        $fatal(1,"polar complete RAM mismatch cycle=%0d row=%0d",cycles,row);
                end
                all_row_compares=all_row_compares+1;
            end
        end
    endtask

    always @(posedge clk)begin
        cycles=cycles+1;
        write0_before=o0.v[3];write1_before=o1.v[3];addr0_before=o0.addr3;addr1_before=o1.addr3;
        collision0_before=o0.v[3] && o0.issue && o0.address_now==o0.addr3;
        collision1_before=o1.v[3] && o1.issue && o1.address_now==o1.addr3;
        if(rst_n)begin
            if(n0.state_write_valid !== o0.v[3] || n1.state_write_valid !== o1.v[3])
                $fatal(1,"polar write-valid alignment mismatch cycle=%0d",cycles);
            if(o0.v[3])begin
                writes0=writes0+1;
                if(n0.state_write_address !== o0.addr3 ||
                   n0.state_write_data !== {o0.end3,o0.ptr3,o0.aL3,o0.aR3,o0.tL3,o0.tR3,o0.enabled3 ? o0.phase_after : 32'd0})
                    $fatal(1,"lane0 staged write mismatch cycle=%0d",cycles);
                if(o0.issue && o0.address_now==o0.addr3)begin
                    read_write_same0=read_write_same0+1;
                    if(age!=0 && active && o0.states[o0.address_now][31:0]!=o0.phase_after)
                        sensitive_collision0=sensitive_collision0+1;
                end
            end
            if(o1.v[3])begin
                writes1=writes1+1;
                if(n1.state_write_address !== o1.addr3 ||
                   n1.state_write_data !== {o1.end3,o1.ptr3,o1.aL3,o1.aR3,o1.tL3,o1.tR3,o1.enabled3 ? o1.phase_after : 32'd0})
                    $fatal(1,"lane1 staged write mismatch cycle=%0d",cycles);
                if(o1.issue && o1.address_now==o1.addr3)begin
                    read_write_same1=read_write_same1+1;
                    if(age!=0 && active && o1.states[o1.address_now][31:0]!=o1.phase_after)
                        sensitive_collision1=sensitive_collision1+1;
                end
            end
            if(start)begin
                starts=starts+1;voices_seen[voice]=1;regions_seen[o0.note_region]=1;
                if(age==0)age_zero=age_zero+1;
                if(!active)inactive_starts=inactive_starts+1;
                if(fundamental_ftw!=base_ftw)bent_starts=bent_starts+1;
            end
            if(o0.v[0] && o0.boundary0 && age!=0)boundary0=boundary0+1;
            if(o1.v[0] && o1.boundary0 && age!=0)boundary1=boundary1+1;
            if(o0.v[0] && o0.s0[194:175]==20'hfffff)terminal0=terminal0+1;
            if(o1.v[0] && o1.s0[194:175]==20'hfffff)terminal1=terminal1+1;
        end
        #1;compare_state();
        if(rst_n && ov0 && ov1)begin
            outputs=outputs+1;
            if(ol0!=0 || or0!=0 || ol1!=0 || or1!=0)nonzero_outputs=nonzero_outputs+1;
        end
    end

    function [31:0] ftw_for_region(input integer region);
        case(region%4)
            0:ftw_for_region=20000000;
            1:ftw_for_region=35000000;
            2:ftw_for_region=55000000;
            default:ftw_for_region=80000000;
        endcase
    endfunction
    task drive_cycle(input bit do_start,input integer id,input bit is_active,
                     input integer note_age,input reg [31:0] base,input reg [31:0] bent);
        begin
            // Drive after the falling-edge stage has sampled: no TB/DUT race.
            @(negedge clk);#1;
            start=do_start;voice=id;active=is_active;age=note_age;base_ftw=base;fundamental_ftw=bent;
            @(posedge clk);#2;
        end
    endtask
    task idle_cycles(input integer count);
        integer k;
        begin for(k=0;k<count;k=k+1)drive_cycle(0,voice,active,age,base_ftw,fundamental_ftw);end
    endtask
    task run_voice(input integer id,input bit is_active,input integer note_age,
                   input reg [31:0] base,input reg [31:0] bent);
        begin
            drive_cycle(1,id,is_active,note_age,base,bent);
            idle_cycles(13);
        end
    endtask
    task reset_pending(input bit after_falling);
        begin
            // Four rising edges move pair0 into v[3], ready for the next RAM
            // write. Cancel either side of its new falling-edge staging.
            drive_cycle(1,7,1,0,ftw_for_region(3),ftw_for_region(3));
            idle_cycles(3);
            if(after_falling)begin
                @(negedge clk);#1;
                if(!n0.state_write_valid || !n1.state_write_valid)
                    $fatal(1,"reset-after-fall fixture missed pending write");
                rst_n=0;#1;rst_n=1;reset_after_fall=reset_after_fall+1;
            end else begin
                // Current instant is rising edge +2ns, before falling edge.
                rst_n=0;#1;rst_n=1;reset_before_fall=reset_before_fall+1;
            end
            idle_cycles(12);
        end
    endtask

    integer seed=471833,random_transactions=1000,id,region,k,batch;
    integer ages[0:63];
    reg [31:0] random_value=1,base,bent;
    function [31:0] next_random(input reg [31:0] previous);
        reg [31:0] x;
        begin x=previous^(previous<<13);x=x^(x>>17);next_random=x^(x<<5);end
    endfunction
    initial begin
        if($value$plusargs("SEED=%d",seed))begin end
        if($value$plusargs("TRANSACTIONS=%d",random_transactions))begin end
        random_value=seed;oracle_negative=$test$plusargs("ORACLE_NEGATIVE");
        #1;rst_n=0;idle_cycles(3);rst_n=1;idle_cycles(2);
        // Initialize every private voice/partial address using age0, covering
        // all four note regions and both even/odd lanes with the real ROMs.
        for(id=0;id<64;id=id+1)begin
            ages[id]=0;run_voice(id,1,0,ftw_for_region(id),ftw_for_region(id));
        end
        // Exact end values in the first ROM segment are 9 samples. Include
        // below/equal/above boundaries and reset/inactive initialization.
        for(region=0;region<4;region=region+1)begin
            run_voice(region,1,8,ftw_for_region(region),ftw_for_region(region));
            run_voice(region,1,9,ftw_for_region(region),ftw_for_region(region));
            run_voice(region,1,10,ftw_for_region(region),ftw_for_region(region)+1000);
            run_voice(region,0,11,ftw_for_region(region),ftw_for_region(region)-1000);
            run_voice(region,0,0,ftw_for_region(region),ftw_for_region(region));
        end
        // Start every four cycles on the SAME voice. Use nonzero age after a
        // real phase update: initialization must not mask read/write ordering.
        // At all four partial addresses, the old phase differs from the phase
        // being written. Early falling-edge RAM writes must fail s0 comparison.
        for(region=0;region<4;region=region+1)begin
            run_voice(5,1,0,ftw_for_region(region),ftw_for_region(region));
            run_voice(5,1,1,ftw_for_region(region),ftw_for_region(region));
            for(batch=0;batch<32;batch=batch+1)begin
                drive_cycle(1,5,1,1,ftw_for_region(region),ftw_for_region(region));idle_cycles(3);
            end
            idle_cycles(14);
        end
        // Visit the terminal segment without permitting pointer rollover into
        // another note region, then explicitly restart the voice at age0.
        for(batch=0;batch<40;batch=batch+1)
            run_voice(12,1,20'hffffe,ftw_for_region(0),ftw_for_region(0));
        run_voice(12,1,0,ftw_for_region(0),ftw_for_region(0));
        // Asynchronous reset pulses straddle different clock phases and cancel
        // a genuinely pending buffered write; RAM contents itself is retained.
        reset_pending(0);reset_pending(1);
        for(k=0;k<random_transactions;k=k+1)begin
            random_value=next_random(random_value);id=random_value[5:0];
            ages[id]=ages[id]+1+random_value[14:8];
            if(random_value[19:16]==0)ages[id]=0;
            base=ftw_for_region(id);
            bent=base+(random_value[24] ? random_value[23:8] : -random_value[23:8]);
            if(random_value[28:25]==0)bent=32'h70000000; // anti-alias mute branch
            run_voice(id,random_value[31:29]!=0,ages[id],base,bent);
            if(k%127==126)begin reset_pending(k[7]);run_voice(id,1,0,base,base);end
        end
        idle_cycles(20);
        if(voices_seen!==64'hffffffffffffffff || regions_seen!==4'hf || starts<1000 || outputs<1000 ||
           nonzero_outputs<10 || writes0<4000 || writes1<4000 || read_write_same0<10 || read_write_same1<10 ||
           boundary0<20 || boundary1<20 || terminal0<10 || terminal1<10 || age_zero<64 || inactive_starts<10 ||
           bent_starts<100 || reset_before_fall<1 || reset_after_fall<1 || all_row_compares<100 ||
           read_state_compares!=cycles || sensitive_collision0<200 || sensitive_collision1<200)
            $fatal(1,"polar coverage insufficient starts=%0d outputs=%0d nonzero=%0d writes=%0d/%0d collision=%0d/%0d boundary=%0d/%0d terminal=%0d/%0d reset=%0d/%0d read_states=%0d/%0d sensitive=%0d/%0d",
                starts,outputs,nonzero_outputs,writes0,writes1,read_write_same0,read_write_same1,
                boundary0,boundary1,terminal0,terminal1,reset_before_fall,reset_after_fall,
                read_state_compares,cycles,sensitive_collision0,sensitive_collision1);
        $display("POLAR LANE EQUIVALENCE PASS seed=%0d cycles=%0d starts=%0d outputs=%0d nonzero=%0d writes=%0d/%0d same_address=%0d/%0d boundaries=%0d/%0d terminal=%0d/%0d resets=%0d/%0d all_rows=%0d age0=%0d inactive=%0d bent=%0d read_states=%0d sensitive_collisions=%0d/%0d",
            seed,cycles,starts,outputs,nonzero_outputs,writes0,writes1,read_write_same0,read_write_same1,
            boundary0,boundary1,terminal0,terminal1,reset_before_fall,reset_after_fall,all_row_compares,age_zero,inactive_starts,bent_starts,
            read_state_compares,sensitive_collision0,sensitive_collision1);
        $finish;
    end
    initial begin #5000000;$fatal(1,"polar equivalence timeout");end
endmodule
