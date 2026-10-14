`timescale 1ns/1ps
module tb_mono_diag_contract;
    reg clk=0, rst_n=0, start=0, stop=0, frame_tick=0;
    reg cmd_ready=0, done_valid=0;
    wire cmd_valid, cmd_on, done_ready, busy, start_ready, active;
    wire [6:0] cmd_note;
    wire [1:0] cmd_timbre;
    wire [4:0] sequence_index;
    always #10 clk=~clk;
    mono_diag_sequence #(.SINE_ON_FRAMES(3), .PIANO_ON_FRAMES(3),
        .GAP_FRAMES(2), .MARKER_FRAMES(4)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .stop(stop), .frame_tick(frame_tick),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_on(cmd_on),
        .cmd_note(cmd_note), .cmd_timbre(cmd_timbre), .done_valid(done_valid),
        .done_ready(done_ready), .busy(busy), .start_ready(start_ready),
        .active(active), .sequence_index(sequence_index));
    reg signed [31:0] extreme_left=32767, extreme_right=-32768;
    reg [11:0] extreme_gain=4095;
    wire signed [23:0] gained_left, gained_right;
    gain_saturator #(.SHIFT(7)) gain_extremes (
        .clk(clk), .mix_left(extreme_left), .mix_right(extreme_right),
        .gain(extreme_gain), .out_left(gained_left), .out_right(gained_right));
    integer i, ready_before;
    reg [9:0] payload;
    task automatic stall_check(input integer cycles);
        begin
            payload={cmd_on,cmd_note,cmd_timbre};
            for(i=0;i<cycles;i=i+1) begin
                @(negedge clk);
                if(!cmd_valid || payload!=={cmd_on,cmd_note,cmd_timbre})
                    $fatal(1,"Presented command changed/cancelled under ready backpressure");
            end
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);
        if(gained_left!==24'sd8386304 || gained_right!==-24'sd8386560)
            $fatal(1,"SHIFT=7 signed maximum gain incorrect L=%0d R=%0d",gained_left,gained_right);
        if(gained_left==24'h7fffff || gained_right==24'h800000)
            $fatal(1,"One-voice extreme maximum gain clipped");
        extreme_left=-32768; extreme_right=32767;
        repeat(2) @(negedge clk);
        if(gained_left!==-24'sd8386560 || gained_right!==24'sd8386304)
            $fatal(1,"SHIFT=7 signed extreme polarity swap incorrect");
        extreme_gain=0;
        repeat(2) @(negedge clk);
        if(gained_left!==0 || gained_right!==0)
            $fatal(1,"SHIFT=7 zero gain not silent");
        extreme_gain=2048;
        repeat(2) @(negedge clk);
        if(gained_left!==-24'sd4194304 || gained_right!==24'sd4194176)
            $fatal(1,"SHIFT=7 unity gain signed extremes incorrect");
        rst_n=1; cmd_ready=1; wait(start_ready);
        @(negedge clk); start=1;
        @(posedge clk); #0.001; cmd_ready=0;
        stall_check(5);
        // Stop while note-on is already presented must retain the request.
        stop=1; stall_check(5); stop=0; stall_check(2);
        if(!cmd_on) $fatal(1,"Stop mutated stalled note-on");
        cmd_ready=1;
        @(posedge clk); #0.001;
        if(!cmd_valid || cmd_on || !active) $fatal(1,"Cancelled start failed to pair its accepted note-on with note-off");
        cmd_ready=0; stall_check(5);
        stop=1; stall_check(2); stop=0; stall_check(2);
        if(cmd_on) $fatal(1,"Stop mutated stalled note-off");
        cmd_ready=1;
        @(posedge clk); #0.001;
        if(!done_ready || !active) $fatal(1,"Release completion not awaited");
        repeat(5) @(negedge clk);
        if(!busy || start_ready) $fatal(1,"Ready announced before release completion");
        done_valid=1; @(posedge clk); #0.001; done_valid=0;
        if(active || busy) $fatal(1,"Stop did not end after done handshake");
        // Start still held: no fresh rising edge, so no automatic restart.
        repeat(10) @(negedge clk);
        if(busy || cmd_valid) $fatal(1,"Held start replayed after stop");
        start=0; repeat(2) @(negedge clk); start=1;
        wait(cmd_valid && cmd_on); @(posedge clk); #0.001;
        if(!active || !busy || done_ready) $fatal(1,"Restart did not hold a new voice");
        // done_valid outside TAIL must not be acknowledged or release voice.
        done_valid=1; repeat(3) @(negedge clk);
        if(done_ready || !active) $fatal(1,"Done completion acknowledged outside release TAIL");
        done_valid=0; stop=1;
        wait(cmd_valid && !cmd_on); @(posedge clk); #0.001; stop=0;
        done_valid=1; @(posedge clk); #0.001; done_valid=0;
        if(busy || active) $fatal(1,"Second stop did not complete");
        rst_n=0; @(negedge clk);
        if(cmd_valid || done_ready || busy || active) $fatal(1,"Controller reset contract failed");
        $display("MONO DIAGNOSTIC CONTRACT PASSED stalled_on_stop=1 stalled_off_stop=1 complete_release=1 held_start=1 signed_extreme_gains=0/2048/4095 no_clipping=1");
        $finish;
    end
    initial begin #100000; $fatal(1,"Diagnostic contract timeout"); end
endmodule
