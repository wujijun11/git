`timescale 1ps/1ps
module tb_audio_clock_48k;
    reg clk_50=0;
    wire clk_audio, locked;
    audio_clock_48k dut (.clk_50(clk_50), .clk_audio(clk_audio), .locked(locked));
    always #10000 clk_50=~clk_50;

    time start_time, elapsed;
    initial begin
        wait (locked);
        @(posedge clk_audio);
        start_time=$time;
        repeat (3072) @(posedge clk_audio);
        elapsed=$time-start_time;
        // 3072 cycles at 49.152 MHz last exactly 62.5 us.
        // Gowin's 1 ps-resolution model rounds each output half period,
        // accumulating about 3 ns over this interval.
        if (elapsed < 62495000 || elapsed > 62505000)
            $fatal(1,"audio PLL interval %0d ps, expected 62500000 ps",elapsed);
        if (!locked) $fatal(1,"PLL lost lock during interval");
        $display("PASS audio PLL: 3072 cycles in %0d ps",elapsed);
        $finish;
    end
    initial begin
        #1000000000;
        $display("PLL after 1ms: pll0 raw=%b lock=%b rst=%b; pll1 raw=%b lock=%b",
            dut.pll_38m4.primitive_lock, dut.lock_38m4,
            dut.pll_38m4.primitive_reset,
            dut.pll_49m152.primitive_lock, dut.lock_49m152);
        #9000000000;
        $fatal(1,"audio PLL did not lock within 10 ms: pll0 raw=%b lock=%b rst=%b stable=%b; pll1 raw=%b lock=%b rst=%b stable=%b",
            dut.pll_38m4.primitive_lock, dut.lock_38m4,
            dut.pll_38m4.primitive_reset,
            dut.first_lock_stable, dut.pll_49m152.primitive_lock,
            dut.lock_49m152, dut.pll_49m152.primitive_reset,
            dut.second_lock_stable);
    end
endmodule
