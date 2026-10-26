`timescale 1ns/1ps
// 与已通过的上一版FIFO逐拍比较：容量、反压、顺序、同时读写和异步复位。
module fifo_pipeline_fixture #(
    parameter integer AW = 6,
    parameter integer SOURCE_W = 6,
    parameter integer SEED = 37
)(output reg finished = 0);
    localparam integer DEPTH = 1 << AW;
    localparam integer WIDTH = 17 + SOURCE_W;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg push_valid = 0, pop_ready = 0;
    reg [WIDTH-1:0] payload = 0;
    wire ready_new, ready_old, valid_new, valid_old;
    wire full_new, full_old, empty_new, empty_old;
    wire [WIDTH-1:0] result_new, result_old;
    wire [AW:0] level_new, level_old;
    integer seed = SEED;
    integer cycles = 0, accepted = 0, popped = 0, forwarded = 0;
    reg accepted_last = 0;

    event_fifo_v2 #(.DEPTH(DEPTH), .AWIDTH(AW), .SOURCE_WIDTH(SOURCE_W)) candidate(
        .clk(clk), .rst_n(rst_n), .push_valid(push_valid), .push_ready(ready_new),
        .push_on(payload[WIDTH-1]), .push_source(payload[WIDTH-2 -: SOURCE_W]),
        .push_note(payload[15:9]), .push_velocity(payload[8:2]), .push_timbre(payload[1:0]),
        .pop_valid(valid_new), .pop_ready(pop_ready), .pop_on(result_new[WIDTH-1]),
        .pop_source(result_new[WIDTH-2 -: SOURCE_W]), .pop_note(result_new[15:9]),
        .pop_velocity(result_new[8:2]), .pop_timbre(result_new[1:0]),
        .level(level_new), .full(full_new), .empty(empty_new));
    event_fifo_v2_pipeline_reference #(.DEPTH(DEPTH), .AWIDTH(AW), .SOURCE_WIDTH(SOURCE_W)) reference_model(
        .clk(clk), .rst_n(rst_n), .push_valid(push_valid), .push_ready(ready_old),
        .push_on(payload[WIDTH-1]), .push_source(payload[WIDTH-2 -: SOURCE_W]),
        .push_note(payload[15:9]), .push_velocity(payload[8:2]), .push_timbre(payload[1:0]),
        .pop_valid(valid_old), .pop_ready(pop_ready), .pop_on(result_old[WIDTH-1]),
        .pop_source(result_old[WIDTH-2 -: SOURCE_W]), .pop_note(result_old[15:9]),
        .pop_velocity(result_old[8:2]), .pop_timbre(result_old[1:0]),
        .level(level_old), .full(full_old), .empty(empty_old));

    // 独立队列模型验证有效负载；不能只让两个实现互相比出相同错误。
    reg [WIDTH-1:0] expected [0:65535];
    integer wr = 0, rd = 0;
    always @(negedge rst_n) begin wr = 0; rd = 0; end
    always @(posedge clk) begin
        accepted_last = rst_n && push_valid && ready_old;
        if (rst_n) begin
            if (valid_old && pop_ready) begin
                if (rd >= wr || result_new !== expected[rd])
                    $fatal(1, "FIFO scoreboard depth=%0d cycle=%0d", DEPTH, cycles);
                rd = rd + 1;
                popped = popped + 1;
            end
            if (accepted_last) begin
                expected[wr] = payload;
                wr = wr + 1;
                accepted = accepted + 1;
            end
            if (candidate.read_ram && candidate.pending_write_valid &&
                candidate.pending_write_address == candidate.rptr)
                forwarded = forwarded + 1;
        end
        #1;
        cycles = cycles + 1;
        if ({ready_new,valid_new,full_new,empty_new,level_new,result_new} !==
            {ready_old,valid_old,full_old,empty_old,level_old,result_old})
            $fatal(1, "FIFO cycle mismatch depth=%0d cycle=%0d", DEPTH, cycles);
    end

    task drive(input bit sending, input bit receiving);
        begin
            @(negedge clk);
            pop_ready = receiving;
            // 有效请求被反压时保持，不用不断覆盖未发送事件来制造假流量。
            if (!push_valid || accepted_last) begin
                push_valid = sending;
                payload = $random(seed);
            end
        end
    endtask

    integer n;
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        // 空队列旁路、满队列停顿、连续出入与地址回绕。
        repeat (DEPTH + 8) drive(1, 0);
        repeat (5) drive(1, 0);
        repeat (DEPTH * 4 + 20) drive(1, 1);
        for (n = 0; n < 16000; n = n + 1) begin
            drive(($random(seed) & 7) != 0, ($random(seed) & 3) != 0);
            if (n % 997 == 120) begin
                // 故意在两拍之间、有效请求尚在时复位，检查待写字不会漏回新队列。
                #2 rst_n = 0;
                #11 rst_n = 1;
                push_valid = 0;
            end
        end
        @(negedge clk);
        if (push_valid && !accepted_last) begin
            pop_ready = 1;
            do @(negedge clk); while (!accepted_last);
        end
        push_valid = 0;
        pop_ready = 1;
        repeat (DEPTH + 8) @(negedge clk);
        if (!empty_new || rd != wr || forwarded == 0)
            $fatal(1, "FIFO coverage/drain depth=%0d rd=%0d wr=%0d forward=%0d", DEPTH, rd, wr, forwarded);
        $display("FIFO fixture depth=%0d source=%0d cycles=%0d push=%0d pop=%0d forwarding=%0d",
            DEPTH, SOURCE_W, cycles, accepted, popped, forwarded);
        finished = 1;
    end
endmodule

module tb_event_fifo_pipeline;
    wire [3:0] done;
    fifo_pipeline_fixture #(.AW(1),.SEED(13)) tiny(done[0]);
    fifo_pipeline_fixture #(.AW(3),.SEED(419)) small_queue(done[1]);
    fifo_pipeline_fixture #(.AW(6),.SEED(94177)) board_queue(done[2]);
    fifo_pipeline_fixture #(.AW(2),.SOURCE_W(1),.SEED(7183)) narrow_source(done[3]);
    initial begin
        wait (&done);
        $display("EVENT FIFO PIPELINE PASS");
        $finish;
    end
    initial begin #1000000; $fatal(1, "FIFO pipeline timeout"); end
endmodule
