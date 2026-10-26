`timescale 1ns/1ps
// 独立计分板验证事件负载及来源标签不分离；检查每拍吞吐、反压和异步复位。
module tb_note_event_pipeline;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, in_valid = 0, out_ready = 0;
    reg [24:0] in_payload = 0;
    wire in_ready, out_valid;
    wire [24:0] out_payload;
    note_event_pipeline candidate(.*);
    reg [24:0] expected [0:32767];
    integer wr = 0, rd = 0, accepted = 0, emitted = 0, cycles = 0;
    integer seed = 725937;
    reg input_accepted = 0, previous_stalled = 0;
    reg [24:0] previous_payload = 0;
    always @(negedge rst_n) begin
        wr = 0;
        rd = 0;
        previous_stalled = 0;
    end
    always @(posedge clk) begin
        input_accepted = rst_n && in_valid && in_ready;
        if (rst_n) begin
            if (previous_stalled && (!out_valid || out_payload !== previous_payload))
                $fatal(1, "Event pipeline changed a stalled payload");
            if (out_valid && out_ready) begin
                if (rd >= wr || out_payload !== expected[rd])
                    $fatal(1, "Event pipeline duplicate/lost/reordered payload");
                rd = rd + 1;
                emitted = emitted + 1;
            end
            if (input_accepted) begin
                expected[wr] = in_payload;
                wr = wr + 1;
                accepted = accepted + 1;
            end
            previous_stalled = out_valid && !out_ready;
            previous_payload = out_payload;
        end
        cycles = cycles + 1;
    end
    task drive(input bit sending, input bit receiving);
        begin
            @(negedge clk);
            out_ready = receiving;
            if (!in_valid || input_accepted) begin
                in_valid = sending;
                in_payload = $random(seed);
            end
        end
    endtask
    integer n, before_out;
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        drive(1, 1);
        repeat (2) drive(1, 1);
        before_out = emitted;
        repeat (100) drive(1, 1);
        if (emitted - before_out != 100)
            $fatal(1, "Event pipeline does not sustain one event per clock");
        for (n = 0; n < 12000; n = n + 1) begin
            drive(($random(seed) & 7) != 0, ($random(seed) & 3) != 0);
            if (n % 613 == 30) begin
                #2 rst_n = 0;
                #11 rst_n = 1;
                in_valid = 0;
            end
        end
        @(negedge clk);
        if (in_valid && !input_accepted) begin
            out_ready = 1;
            do @(negedge clk); while (!input_accepted);
        end
        in_valid = 0;
        out_ready = 1;
        repeat (5) @(negedge clk);
        if (out_valid || rd != wr)
            $fatal(1, "Event pipeline did not drain");
        $display("NOTE EVENT PIPELINE PASS cycles=%0d accepted=%0d emitted=%0d", cycles, accepted, emitted);
        $finish;
    end
    initial begin #500000; $fatal(1, "Event pipeline timeout"); end
endmodule
