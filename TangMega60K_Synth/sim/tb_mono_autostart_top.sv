`timescale 1ns/1ps
// Control-contract test only. The real board debounce/WS2812 module is used;
// these stubs intentionally do NOT model PLL frequency or synth/I2S audio.
module audio_clock_48k(input wire clk_50, output wire clk_audio, output wire locked);
    reg allow_lock=0;
    assign clk_audio=clk_50;
    assign locked=allow_lock;
endmodule
module mono_diagnostic_core (
    input wire clk, rst_n, start, stop,
    output wire i2s_bclk, i2s_lrclk, i2s_data,
    output reg busy=0, output wire start_ready, output reg active=0,
    output reg [4:0] sequence_index=0, output reg [31:0] underruns=0
);
    integer starts=0, run_count=0;
    assign start_ready=rst_n && !busy && !stop;
    assign i2s_bclk=0; assign i2s_lrclk=0; assign i2s_data=0;
    always @(posedge clk)
        if(rst_n && start && start_ready) starts=starts+1;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin busy<=0; active<=0; sequence_index<=0; run_count<=0; underruns<=0; end
        else if(stop) begin busy<=0; active<=0; run_count<=0; end
        else if(start && start_ready) begin busy<=1; active<=1; sequence_index<=0; run_count<=0; end
        else if(busy) begin
            if(run_count==299) begin busy<=0; active<=0; end
            else begin
                run_count<=run_count+1;
                if(run_count==99) sequence_index<=5;
            end
        end
    end
endmodule
module tb_mono_autostart_top;
    reg clk=0;
    always #10 clk=~clk;
    reg [2:0] keys_a=3'b111, keys_b=3'b111, keys_c=3'b111, keys_d=3'b111;
    wire rgb_a, rgb_b, rgb_c, pa_a, pa_b, pa_c;
    localparam DELAY=40, HEARTBEAT=7;
    board_mono_autostart_top #(.DEBOUNCE_CYCLES(4), .AUTO_DELAY_CYCLES(DELAY),
        .HEARTBEAT_HALF_CYCLES(HEARTBEAT)) a (.sys_clk(clk), .key_n(keys_a),
        .rgb_data(rgb_a), .pa_disable(pa_a), .i2s_bclk(), .i2s_lrclk(), .i2s_data());
    board_mono_autostart_top #(.DEBOUNCE_CYCLES(4), .AUTO_DELAY_CYCLES(DELAY),
        .HEARTBEAT_HALF_CYCLES(HEARTBEAT)) b (.sys_clk(clk), .key_n(keys_b),
        .rgb_data(rgb_b), .pa_disable(pa_b), .i2s_bclk(), .i2s_lrclk(), .i2s_data());
    board_mono_autostart_top #(.DEBOUNCE_CYCLES(4), .AUTO_DELAY_CYCLES(DELAY),
        .HEARTBEAT_HALF_CYCLES(HEARTBEAT)) c (.sys_clk(clk), .key_n(keys_c),
        .rgb_data(rgb_c), .pa_disable(pa_c), .i2s_bclk(), .i2s_lrclk(), .i2s_data());
    board_mono_autostart_top #(.DEBOUNCE_CYCLES(4), .AUTO_DELAY_CYCLES(DELAY),
        .HEARTBEAT_HALF_CYCLES(HEARTBEAT)) d (.sys_clk(clk), .key_n(keys_d),
        .rgb_data(), .pa_disable(), .i2s_bclk(), .i2s_lrclk(), .i2s_data());
    integer cycles=0, ready_cycle;
    reg saved_heartbeat;
    always @(posedge clk) cycles=cycles+1;
    task automatic step(input integer count);
        repeat(count) begin @(posedge clk); #1; end
    endtask
    task automatic a_key(input integer index, input bit down);
        begin @(negedge clk); keys_a[index]=!down; step(12); end
    endtask
    initial begin
        wait(a.board_ready && b.board_ready && c.board_ready && d.board_ready);
        step(3); saved_heartbeat=a.heartbeat; step(HEARTBEAT);
        if(a.heartbeat===saved_heartbeat || a.pll_sync || a.u_diag.starts)
            $fatal(1,"50MHz heartbeat or no-PLL idle contract failed");
        wait(a.heartbeat); #1;
        if(a.status_grb!==24'h001000) $fatal(1,"No-lock red status missing");
        @(negedge clk);
        a.u_audio_clock.allow_lock=1; b.u_audio_clock.allow_lock=1;
        c.u_audio_clock.allow_lock=1; d.u_audio_clock.allow_lock=1;
        wait(a.pll_sync); #1; ready_cycle=cycles;
        // Cancel two other instances during the pending automatic wait.
        @(negedge clk); keys_b[1]=0; keys_c[2]=0; keys_d[0]=0;
        step(12);
        if(b.auto_armed || c.auto_armed || b.u_diag.starts || c.u_diag.starts)
            $fatal(1,"KEY1/KEY2 failed to cancel pending autostart");
        if(d.u_diag.starts!=1 || !d.auto_ack || d.auto_armed)
            $fatal(1,"Manual start before automatic deadline did not consume pending auto");
        @(negedge clk); keys_d[0]=1;
        while(!a.u_diag.starts) begin
            step(1);
            if(cycles-ready_cycle>DELAY+20) $fatal(1,"Autostart failed to arrive");
        end
        if(cycles-ready_cycle<DELAY || a.u_diag.starts!=1 || !a.busy)
            $fatal(1,"Automatic start did not respect delay/one-shot");
        step(5);
        if(a.auto_armed || !a.auto_ack) $fatal(1,"Accepted auto was not permanently acknowledged");
        // A held KEY0 beginning during playback must not cause a later replay.
        a_key(0,1); step(350);
        if(a.u_diag.starts!=1 || a.busy) $fatal(1,"Busy/held KEY0 replayed");
        a_key(0,0); a_key(0,1);
        if(a.u_diag.starts!=2 || !a.busy) $fatal(1,"Released/repressed KEY0 failed to restart");
        a_key(0,0);
        a_key(2,1);
        if(a.busy || a.rst_n || !a.auto_ack || a.auto_armed)
            $fatal(1,"KEY2 did not reset while retaining one-shot consumption");
        a_key(2,0); step(350);
        if(a.u_diag.starts!=2 || a.busy) $fatal(1,"KEY2 release unexpectedly replayed auto");
        // A PLL loss after a successful start cannot re-arm playback.
        @(negedge clk); a.u_audio_clock.allow_lock=0;
        step(15);
        if(a.rst_n || !a.auto_ack || a.auto_armed) $fatal(1,"PLL loss erased accepted one-shot");
        saved_heartbeat=a.heartbeat; step(HEARTBEAT);
        if(a.heartbeat===saved_heartbeat) $fatal(1,"Heartbeat depended on PLL lock");
        @(negedge clk); a.u_audio_clock.allow_lock=1;
        step(DELAY+350);
        if(a.u_diag.starts!=2 || a.busy) $fatal(1,"PLL recovery unexpectedly replayed auto");
        a_key(0,1);
        if(a.u_diag.starts!=3) $fatal(1,"Manual start after PLL recovery failed");
        a_key(0,0); a_key(1,1);
        if(a.busy) $fatal(1,"KEY1 failed to stop active playback");
        a_key(1,0); step(350);
        if(a.u_diag.starts!=3) $fatal(1,"Stop release replayed");
        // Both pending-cancelled instances remain silent, but manual restart works.
        @(negedge clk); keys_b[1]=1; keys_c[2]=1;
        step(DELAY+350);
        if(b.u_diag.starts || c.u_diag.starts) $fatal(1,"Cancelled auto later replayed");
        @(negedge clk); keys_b[0]=0; keys_c[0]=0;
        step(12);
        if(b.u_diag.starts!=1 || c.u_diag.starts!=1) $fatal(1,"Manual start after pending cancel failed");
        if(pa_a!==1 || pa_b!==1 || pa_c!==1) $fatal(1,"Onboard amplifier was enabled");
        // Hold and release KEY0; pending automatic start is consumed by manual play.
        @(negedge clk); keys_b[0]=1; keys_c[0]=1;
        step(350);
        if(b.u_diag.starts!=1 || c.u_diag.starts!=1) $fatal(1,"Manual play repeated automatically");
        if(d.u_diag.starts!=1 || d.busy) $fatal(1,"Early manual play was followed by automatic replay");
        $display("MONO AUTOSTART CONTROL PASSED automatic-delay/once KEY1-cancel/stop KEY2-cancel/reset/manual busy-held-ignore PLL-loss-no-rearm 50MHz-heartbeat; PLL/core-stub only");
        $finish;
    end
    initial begin #3000000; $fatal(1,"Autostart control test timeout"); end
endmodule
