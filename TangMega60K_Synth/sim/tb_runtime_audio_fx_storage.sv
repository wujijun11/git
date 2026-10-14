`timescale 1ns/1ps

// Compare the shared banks against the frozen, separated-history RTL on every
// clock. Long mode runs cover fill guards and wrap at the production lengths.
module fx_storage_case #(
    parameter CASE_ID=0,
    parameter HIST_SIZE=2048,HIST_AW=11,DELAY_LENGTH=1920,
    parameter CHORUS_BASE=480,CHORUS_DEPTH=96,
    parameter COMB0=1493,COMB1=1601,COMB2=1747,COMB3=1879,
    parameter AP0=113,AP1=337,
    parameter FRAMES_PER_MODE=4000
) (input wire clk,output reg done=0);
    reg rst_n=0,in_valid=0,out_ready=0;
    reg [1:0] mode=0;
    reg signed [23:0] in_left=0,in_right=0;
    wire in_ready,out_valid,ref_in_ready,ref_out_valid;
    wire signed [23:0] out_left,out_right,ref_out_left,ref_out_right;
    runtime_audio_fx #(
        .HIST_SIZE(HIST_SIZE),.HIST_AW(HIST_AW),.DELAY_LENGTH(DELAY_LENGTH),
        .CHORUS_BASE(CHORUS_BASE),.CHORUS_DEPTH(CHORUS_DEPTH),
        .COMB0(COMB0),.COMB1(COMB1),.COMB2(COMB2),.COMB3(COMB3),.AP0(AP0),.AP1(AP1)
    ) dut(.*);
    runtime_audio_fx_reference #(
        .HIST_SIZE(HIST_SIZE),.HIST_AW(HIST_AW),.DELAY_LENGTH(DELAY_LENGTH),
        .CHORUS_BASE(CHORUS_BASE),.CHORUS_DEPTH(CHORUS_DEPTH),
        .COMB0(COMB0),.COMB1(COMB1),.COMB2(COMB2),.COMB3(COMB3),.AP0(AP0),.AP1(AP1)
    ) reference(
        .clk(clk),.rst_n(rst_n),.mode(mode),.in_valid(in_valid),.in_ready(ref_in_ready),
        .in_left(in_left),.in_right(in_right),.out_valid(ref_out_valid),.out_ready(out_ready),
        .out_left(ref_out_left),.out_right(ref_out_right)
    );
    integer frames=0,cycles=0,outputs=0;
    integer seed,choice;
    reg last_accept=0;
    reg history_full=0,reverb_full=0,history_wrap=0,comb_wrap=0,allpass_wrap=0;
    always @(posedge clk) begin
        last_accept=rst_n && in_valid && in_ready;
        if(last_accept) frames=frames+1;
        if(rst_n && out_valid && out_ready) outputs=outputs+1;
        if(rst_n) begin
            if(dut.filled==HIST_SIZE) history_full=1;
            if(dut.cfill0==COMB0 && dut.cfill1==COMB1 && dut.cfill2==COMB2 &&
                dut.cfill3==COMB3 && dut.afill0==AP0 && dut.afill1==AP1) reverb_full=1;
            if(dut.state==1 && (dut.active_mode==1 || dut.active_mode==3) &&
                dut.ptr==HIST_SIZE-1) history_wrap=1;
            if(dut.state==1 && dut.active_mode==2 && dut.cptr3==COMB3-1) comb_wrap=1;
            if(dut.state==3 && dut.aptr1==AP1-1) allpass_wrap=1;
        end
        #1;
        if(in_ready!==ref_in_ready || out_valid!==ref_out_valid)
            $fatal(1,"case %0d handshake mismatch at cycle %0d",CASE_ID,cycles);
        if(out_valid && (out_left!==ref_out_left || out_right!==ref_out_right))
            $fatal(1,"case %0d data mismatch frame=%0d mode=%0d got=%0d,%0d expected=%0d,%0d",
                CASE_ID,frames,mode,out_left,out_right,ref_out_left,ref_out_right);
        if(out_valid && (^{out_left,out_right})===1'bx)
            $fatal(1,"case %0d uninitialized output frames=%0d cycles=%0d mode=%0d active=%0d left=%h right=%h ref=%h,%h",
                CASE_ID,frames,cycles,mode,dut.active_mode,out_left,out_right,ref_out_left,ref_out_right);
    end
    initial begin
        seed=32'h136af04d+CASE_ID;
        while(frames<16*FRAMES_PER_MODE) begin
            @(negedge clk);
            cycles=cycles+1;
            // Reset during active/stalled frames, while retaining randomized
            // memory contents. Both implementations must suppress old tails.
            rst_n=(cycles%50000)>=3;
            out_ready=($random(seed)&7)!=0;
            if(!rst_n) begin
                in_valid=0;
            end else if(!in_valid || last_accept) begin
                in_valid=($random(seed)&3)!=0;
                choice=$random(seed)&15;
                case(choice)
                    0: begin in_left=24'h7fffff;in_right=24'h800000;end
                    1: begin in_left=24'h800000;in_right=24'h7fffff;end
                    2: begin in_left=0;in_right=0;end
                    3: begin in_left=1;in_right=-1;end
                    default: begin in_left=$random(seed);in_right=$random(seed);end
                endcase
            end
            mode=(frames/FRAMES_PER_MODE)%4;
            // Mode is an independent control. Also exercise changes while the
            // FSM or output stall is still completing the previous frame.
            if(frames>=12*FRAMES_PER_MODE && !in_ready && ($random(seed)&15)==0)
                mode=$random(seed);
        end
        @(negedge clk);in_valid=0;out_ready=1;
        repeat(10)@(negedge clk);
        if(!history_full || !reverb_full || !history_wrap || !comb_wrap || !allpass_wrap)
            $fatal(1,"case %0d incomplete fill/wrap coverage: %b%b%b%b%b",CASE_ID,
                history_full,reverb_full,history_wrap,comb_wrap,allpass_wrap);
        $display("FX STORAGE CASE %0d PASS frames=%0d outputs=%0d cycles=%0d",
            CASE_ID,frames,outputs,cycles);
        done=1;
    end
endmodule

module tb_runtime_audio_fx_storage;
    reg clk=0;always #5 clk=~clk;
    wire production_done,small_done,extended_done;
    fx_storage_case production(.clk(clk),.done(production_done));
    fx_storage_case #(
        .CASE_ID(1),.HIST_SIZE(64),.HIST_AW(6),.DELAY_LENGTH(8),
        .CHORUS_BASE(4),.CHORUS_DEPTH(4),.COMB0(7),.COMB1(11),
        .COMB2(13),.COMB3(17),.AP0(3),.AP1(5),.FRAMES_PER_MODE(400)
    ) scaled_case(.clk(clk),.done(small_done));
    // Verify banks grow for legal parameter sets whose reverb histories are
    // longer than the delay history; no capacity is silently truncated.
    fx_storage_case #(
        .CASE_ID(2),.HIST_SIZE(32),.HIST_AW(5),.DELAY_LENGTH(24),
        .CHORUS_BASE(10),.CHORUS_DEPTH(8),.COMB0(31),.COMB1(37),
        .COMB2(41),.COMB3(43),.AP0(11),.AP1(13),.FRAMES_PER_MODE(400)
    ) extended(.clk(clk),.done(extended_done));
    initial begin
        wait(production_done && small_done && extended_done);
        $display("RUNTIME AUDIO FX STORAGE PASS bit-exact shared/separate histories");
        $finish;
    end
    initial begin #10000000;$fatal(1,"storage regression timeout");end
endmodule
