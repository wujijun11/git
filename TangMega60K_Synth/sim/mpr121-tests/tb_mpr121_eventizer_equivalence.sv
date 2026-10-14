`timescale 1ns/1ps
module tb_mpr121_eventizer_capacity;
    reg clk=0;always #5 clk=~clk;
    reg resetn=0;
    reg [2:0] snapshot_valid=0;
    wire [2:0] snapshot_ready;
    reg [7:0] touch0=0,touch1=0;
    reg [8:0] touch2=0;
    reg [2:0] fault=0;
    reg [174:0] key_map_flat;
    reg [1:0] current_timbre=2;
    wire key_valid,key_on;
    reg key_ready=0;
    wire [5:0] key_source;
    wire [6:0] key_note,key_velocity;
    wire [1:0] key_timbre;
    wire [24:0] touch_mask;
    wire overflow;
    wire [15:0] pending_events;
    mpr121_key_eventizer dut(.*);
    wire [2:0] snapshot_ready_original;
    wire key_valid_original,key_on_original,overflow_original;
    wire [5:0] key_source_original;
    wire [6:0] key_note_original,key_velocity_original;
    wire [1:0] key_timbre_original;
    wire [24:0] touch_mask_original;
    wire [15:0] pending_events_original;
    mpr121_key_eventizer_original original(
        .clk(clk),.resetn(resetn),.snapshot_valid(snapshot_valid),.snapshot_ready(snapshot_ready_original),
        .touch0(touch0),.touch1(touch1),.touch2(touch2),.fault(fault),.key_map_flat(key_map_flat),
        .current_timbre(current_timbre),.key_valid(key_valid_original),.key_ready(key_ready),
        .key_on(key_on_original),.key_source(key_source_original),.key_note(key_note_original),
        .key_velocity(key_velocity_original),.key_timbre(key_timbre_original),
        .touch_mask(touch_mask_original),.overflow(overflow_original),.pending_events(pending_events_original));
    always @(negedge clk) begin
        if({snapshot_ready,key_valid,touch_mask,overflow,pending_events}!==
           {snapshot_ready_original,key_valid_original,touch_mask_original,overflow_original,pending_events_original})
            $fatal(1,"cycle mismatch in control/state vs original RTL");
        if(key_valid && {key_on,key_source,key_note,key_velocity,key_timbre}!==
           {key_on_original,key_source_original,key_note_original,key_velocity_original,key_timbre_original})
            $fatal(1,"cycle mismatch in event payload vs original RTL");
    end

    reg [22:0] expected[0:8191];
    integer written=0,received=0;
    reg [24:0] model_touch=0;
    reg [6:0] model_note[0:24];
    reg [1:0] model_timbre[0:24];
    reg stalled=0;
    reg [22:0] previous_payload;
    reg random_ready=0;
    reg [31:0] ready_lfsr=32'h5931bc27;
    reg [31:0] data_lfsr=32'ha17d5823;
    integer i,t,iteration,module_index;

    always @(negedge clk) if(random_ready) begin
        ready_lfsr={ready_lfsr[30:0],ready_lfsr[31]^ready_lfsr[21]^ready_lfsr[1]^ready_lfsr[0]};
        key_ready=ready_lfsr[0] && ready_lfsr[3];
    end
    always @(posedge clk) if(resetn) begin
        if(pending_events>64) $fatal(1,"event count exceeded capacity");
        if(overflow) $fatal(1,"complete batch reservation failed");
        if(stalled && (!key_valid || {key_on,key_source,key_note,key_velocity,key_timbre}!==previous_payload))
            $fatal(1,"payload changed while backpressured");
        stalled=key_valid && !key_ready;
        previous_payload={key_on,key_source,key_note,key_velocity,key_timbre};
        if(key_valid && key_ready) begin
            if(received>=written) $fatal(1,"unexpected transition");
            if({key_on,key_source,key_note,key_velocity,key_timbre}!==expected[received])
                $fatal(1,"event %0d mismatch actual=%h expected=%h",received,
                    {key_on,key_source,key_note,key_velocity,key_timbre},expected[received]);
            received=received+1;
        end
    end

    task expect_touch(input [24:0] next_touch);
        integer n;
        reg [5:0] source;
        begin
            for(n=0;n<25;n=n+1) if(next_touch[n]!=model_touch[n]) begin
                source=25+n;
                if(next_touch[n]) begin
                    model_note[n]=key_map_flat[n*7 +:7];
                    model_timbre[n]=current_timbre;
                end
                expected[written]={next_touch[n],source,model_note[n],7'd100,model_timbre[n]};
                written=written+1;
            end
            model_touch=next_touch;
        end
    endtask
    task set_map(input integer base,input [1:0] timbre);
        integer n;
        begin
            for(n=0;n<25;n=n+1) key_map_flat[n*7 +:7]=base+n;
            current_timbre=timbre;
        end
    endtask
    task send_snapshot(input integer m,input [8:0] touches,input bit change_map_after_accept);
        integer timeout;
        reg accepted;
        reg [24:0] next_touch;
        begin
            @(negedge clk);
            case(m)
                0:touch0=touches[7:0];
                1:touch1=touches[7:0];
                2:touch2=touches;
            endcase
            snapshot_valid=1<<m;
            accepted=0;timeout=0;
            while(!accepted && timeout<10000) begin
                @(posedge clk);
                accepted=snapshot_ready[m];timeout=timeout+1;
            end
            if(!accepted) $fatal(1,"snapshot acceptance timeout");
            next_touch=model_touch;
            case(m)
                0:next_touch[7:0]=fault[0]?0:touches[7:0];
                1:next_touch[15:8]=fault[1]?0:touches[7:0];
                2:next_touch[24:16]=fault[2]?0:touches;
            endcase
            expect_touch(next_touch);
            @(negedge clk);snapshot_valid=0;
            // All keys in the accepted batch must retain the accepted mapping.
            if(change_map_after_accept) set_map(37,1);
            timeout=0;
            while(dut.scanning && timeout<10000) begin @(negedge clk);timeout=timeout+1;end
            if(dut.scanning) $fatal(1,"scan did not finish");
        end
    endtask
    task drain_events;
        integer timeout;
        begin
            timeout=0;
            while((received!=written || dut.scanning || dut.release_pending!=0) && timeout<100000) begin
                @(negedge clk);timeout=timeout+1;
            end
            if(received!=written || pending_events!=0 || dut.release_pending!=0)
                $fatal(1,"drain failed received=%0d expected=%0d pending=%0d",received,written,pending_events);
            repeat(5) @(negedge clk);
        end
    endtask

    initial begin
        set_map(60,2);
        for(i=0;i<25;i=i+1) begin model_note[i]=0;model_timbre[i]=0;end
        repeat(5) @(negedge clk);resetn=1;
        send_snapshot(0,9'h0ff,0);send_snapshot(1,9'h0ff,0);send_snapshot(2,9'h1ff,0);
        send_snapshot(0,0,0);send_snapshot(1,0,0);send_snapshot(2,0,0);
        send_snapshot(0,9'h01f,0);send_snapshot(2,9'h1ff,0);
        if(pending_events!=64 || written!=64) $fatal(1,"failed to reach exact full capacity");
        repeat(100) begin
            @(negedge clk);
            if(pending_events!=64 || snapshot_ready!=0) $fatal(1,"full FIFO accepted another batch");
        end
        // A fault waits behind all 64 retained events. Only its five keys release,
        // with their original note/timbre despite changing the live key mapping.
        set_map(90,3);fault=1;
        expect_touch(model_touch & 25'h1ffff00);
        repeat(100) @(negedge clk);
        if(dut.release_pending!=1 || pending_events!=64) $fatal(1,"full FIFO did not defer fault");
        random_ready=1;drain_events();
        if(touch_mask!=25'h1ff0000) $fatal(1,"fault released healthy module keys");
        send_snapshot(0,9'h0ff,0);
        send_snapshot(1,9'h0ff,1);
        send_snapshot(2,0,0);
        drain_events();
        if(model_touch!=25'h000ff00) $fatal(1,"fault isolation mismatch");
        fault=0;set_map(72,0);send_snapshot(0,9'h0ff,1);drain_events();
        set_map(45,3);send_snapshot(0,0,0);send_snapshot(1,0,0);drain_events();

        // Repeated wraparound and simultaneous enqueue/dequeue with deterministic
        // random backpressure exercise count and note-off identity across maps.
        for(iteration=0;iteration<300;iteration=iteration+1) begin
            data_lfsr={data_lfsr[30:0],data_lfsr[31]^data_lfsr[21]^data_lfsr[1]^data_lfsr[0]};
            module_index=data_lfsr[15:8]%3;
            set_map(36+(iteration%40),iteration%4);
            send_snapshot(module_index,data_lfsr[8:0],1);
        end
        send_snapshot(0,0,0);send_snapshot(1,0,0);send_snapshot(2,0,0);drain_events();
        if(model_touch!=0 || touch_mask!=0) $fatal(1,"final releases incomplete");
        // Reset while output is blocked must discard the old queue cleanly.
        random_ready=0;key_ready=0;
        send_snapshot(2,9'h100,0);
        if(pending_events!=1) $fatal(1,"reset precondition missing");
        resetn=0;stalled=0;repeat(3) @(negedge clk);
        written=0;received=0;model_touch=0;
        resetn=1;key_ready=1;
        repeat(10) @(negedge clk);
        if(key_valid || touch_mask!=0 || overflow) $fatal(1,"reset retained queued state");
        send_snapshot(2,9'h100,1);send_snapshot(2,0,0);drain_events();
        $display("PASS tb_mpr121_eventizer_capacity: exact-full FIFO, retained fault releases, original pitch/timbre, batch map capture, 300 random snapshots, wraparound and reset");
        $finish;
    end
    initial begin #20000000;$fatal(1,"capacity watchdog");end
endmodule
