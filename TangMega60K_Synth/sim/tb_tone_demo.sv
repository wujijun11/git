`timescale 1ns/1ps
module tb_tone_demo;
    // Different pitches make swapped channels detectable: L440 / R660 Hz.
    localparam integer N = 12000;
    reg clk=0, rst_n=0;
    always #10.1725 clk=~clk;
    wire bclk, ws, serial;
    wire [31:0] underruns;
    tone_demo_top #(.RIGHT_STEP(32'd59055800)) dut (
        .clk(clk), .rst_n(rst_n), .i2s_bclk(bclk), .i2s_lrclk(ws),
        .i2s_data(serial), .underrun_count(underruns)
    );
    integer frames=0, slot=0, csv, epoch=0, stalls=0;
    integer crossings_l=0, crossings_r=0;
    reg previous_ws=1, synced=0, was_stalled=0;
    reg [47:0] held;
    reg [23:0] shift=0;
    reg signed [23:0] decoded_l=0, decoded_r=0, prev_l=0, prev_r=0;
    real frame_time=0, last_frame_time=0;
    // Mathematical reference uses sample NUMBER, not internal DUT phase/state.
    function integer reference_sample(input integer index, input real step);
        real phase, folded;
        integer truncated;
        begin
            phase=index*step;
            phase=phase-$floor(phase/4294967296.0)*4294967296.0;
            if (phase<2147483648.0) folded=$floor(phase/256.0);
            else folded=8388607.0-$floor((phase-2147483648.0)/256.0);
            truncated=$rtoi(folded)-4194304;
            reference_sample=$rtoi($floor(truncated/4.0));
        end
    endfunction
    always @(posedge clk) if (rst_n) begin
        if (was_stalled && (!dut.valid || {dut.left_sample,dut.right_sample} !== held))
            $fatal(1,"Source changed pending sample under backpressure");
        was_stalled=dut.valid && !dut.ready;
        held={dut.left_sample,dut.right_sample};
        if (was_stalled) stalls=stalls+1;
    end else was_stalled=0;

    // Decode exclusively from external serial pins, including delay/padding.
    always @(posedge bclk or negedge rst_n) begin
        if (!rst_n) begin
            frames=0; slot=0; synced=0; previous_ws=1; shift=0;
            crossings_l=0; crossings_r=0; prev_l=0; prev_r=0;
            last_frame_time=0;
        end else begin
            if (ws != previous_ws) begin
                slot=0; shift=0;
                if (!ws) begin
                    synced=1;
                    frame_time=$realtime;
                    if (last_frame_time!=0 &&
                        ((frame_time-last_frame_time)<20832.0 ||
                         (frame_time-last_frame_time)>20835.0))
                        $fatal(1,"Unexpected sample period");
                    last_frame_time=frame_time;
                end
            end else slot=slot+1;
            previous_ws=ws;
            if (synced) begin
                if (slot==0 || slot>24) begin
                    if (serial !== 1'b0) $fatal(1,"I2S delay/padding not zero");
                end else shift={shift[22:0],serial};
                if (slot==24) begin
                    if (!ws) decoded_l=shift;
                    else begin
                        decoded_r=shift;
                        if ($signed(decoded_l) !== reference_sample(frames,39370534.0) ||
                            $signed(decoded_r) !== reference_sample(frames,59055800.0))
                            $fatal(1,"Tone data mismatch frame=%0d L=%0d R=%0d",frames,decoded_l,decoded_r);
                        if (underruns !== 0) $fatal(1,"Continuous source underrun");
                        if (frames>0 && prev_l<0 && decoded_l>=0) crossings_l=crossings_l+1;
                        if (frames>0 && prev_r<0 && decoded_r>=0) crossings_r=crossings_r+1;
                        prev_l=decoded_l; prev_r=decoded_r;
                        if (epoch==1) $fdisplay(csv,"%0d,%0d",decoded_l,decoded_r);
                        frames=frames+1;
                    end
                end
            end
        end
    end
    initial begin
        csv=$fopen("tone_samples.csv","w");
        if (!csv) $fatal(1,"Cannot create tone_samples.csv");
        repeat(8) @(negedge clk);
        rst_n=1;
        wait(frames==64);
        // Reset mid-frame: oscillator and FIFO must restart together.
        repeat(5) @(negedge clk);
        rst_n=0;
        repeat(8) @(negedge clk);
        epoch=1; rst_n=1;
        wait(frames==N);
        if (crossings_l!=110 || crossings_r!=165 || stalls==0)
            $fatal(1,"Frequency/stall coverage L=%0d R=%0d stalls=%0d",crossings_l,crossings_r,stalls);
        $fclose(csv);
        $display("ALL TONE TESTS PASSED frames=%0d L_crossings=%0d R_crossings=%0d underruns=%0d",frames,crossings_l,crossings_r,underruns);
        $finish;
    end
    initial begin
        #300000000;
        $fatal(1,"Tone test timeout");
    end
endmodule
