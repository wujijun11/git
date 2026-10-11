`timescale 1ns/1ps
module tb_audio_monitor_cdc;
    reg sc=0,dc=0,rn=0,run_dst=1,sv=0;
    always #10 sc=~sc;
    always begin #19;if(run_dst)dc=~dc;end
    reg signed [23:0] l=0,r=0;
    wire dv;wire signed [23:0] dl,dr;wire [31:0] drops;
    audio_monitor_cdc dut(.src_clk(sc),.src_rst_n(rn),.src_valid(sv),.src_left(l),.src_right(r),
        .drop_count(drops),.dst_clk(dc),.dst_rst_n(rn),.dst_valid(dv),.dst_left(dl),.dst_right(dr));
    reg [47:0] expected[0:1023];integer wr=0,rd=0,offered=0;
    always @(posedge sc)if(rn && sv)begin
        offered=offered+1;
        if(dut.req==dut.ack_sync)begin expected[wr]={l,r};wr=wr+1;end
    end
    always @(negedge dc)if(rn && dv)begin
        if(rd>=wr || {dl,dr}!==expected[rd])$fatal(1,"incoherent mailbox sample %d: %h",rd,{dl,dr});
        rd=rd+1;
    end
    task burst(input integer count);
        for(integer k=0;k<count;k=k+1)begin
            @(negedge sc);l=l+24'd12347;r=~l;sv=1;
            @(negedge sc);sv=0;repeat(8)@(negedge sc);
        end
    endtask
    initial begin
        repeat(4)@(negedge sc);rn=1;
        burst(80);
        // A halted display must drop monitoring frames without blocking audio.
        @(negedge dc);run_dst=0;burst(50);run_dst=1;
        burst(80);repeat(30)@(negedge sc);
        if(drops<49 || rd!=wr || rd+drops!=offered)$fatal(1,"mailbox accounting %d/%d drops=%d offered=%d",rd,wr,drops,offered);
        rn=0;repeat(4)@(negedge sc);wr=0;rd=0;offered=0;rn=1;
        burst(20);repeat(30)@(negedge sc);
        if(rd!=20 || drops!=0)$fatal(1,"reset/restart mailbox");
        $display("AUDIO MONITOR CDC PASS coherent stereo, asynchronous clocks, paused display, drops, reset");$finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
