`timescale 1ns/1ps
// 用旧版逐行定义作为独立模型，覆盖非2次幂容量、重复/乱序写和清批次竞争。
module score_tracker_fixture #(
    parameter integer CAPACITY = 1024,
    parameter integer SEED = 913
)(output reg finished = 0);
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, clear = 0, write_valid = 0;
    reg [15:0] write_index = 0, query_count = 0;
    wire complete;
    wire [CAPACITY-1:0] actual_bitmap;
    reg [CAPACITY-1:0] expected_bitmap = 0;
    integer seed = SEED;
    integer checks = 0;
    score_upload_tracker #(.CAPACITY(CAPACITY)) candidate(
        .clk(clk), .rst_n(rst_n), .clear(clear), .write_valid(write_valid),
        .write_index(write_index), .query_count(query_count),
        .complete(complete), .row_written(actual_bitmap));
    always @(posedge clk) begin
        if (!rst_n)
            expected_bitmap <= 0;
        else begin
            if (clear)
                expected_bitmap <= 0;
            if (write_valid && write_index < CAPACITY)
                expected_bitmap[write_index] <= 1'b1;
        end
    end
    task check;
        reg expected_complete;
        integer row;
        begin
            expected_complete = !clear;
            for (row = 0; row < CAPACITY; row = row + 1)
                expected_complete = expected_complete && (expected_bitmap[row] || query_count <= row);
            if (actual_bitmap !== expected_bitmap || complete !== expected_complete)
                $fatal(1, "Tracker mismatch cap=%0d count=%0d clear=%0d write=%0d index=%0d",
                    CAPACITY, query_count, clear, write_valid, write_index);
            checks = checks + 1;
        end
    endtask
    task cycle(input bit clearing, input bit writing, input integer index, input integer count);
        begin
            @(negedge clk);
            clear = clearing;
            write_valid = writing;
            write_index = index;
            query_count = count;
            #1; check();
            @(posedge clk);
            #1; check();
        end
    endtask
    integer n;
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        // 逆序填满，逐行检查刚完成整组、部分组和全容量边界。
        for (n = CAPACITY - 1; n >= 0; n = n - 1)
            cycle(0, 1, n, CAPACITY);
        cycle(0, 0, 0, CAPACITY);
        if (!complete) $fatal(1, "Full upload rejected");
        // 任意16位count都遵循原定义，包括控制器稍后会拒绝的超容量参数。
        if (CAPACITY == 1024) begin
            for (n = 0; n < 65536; n = n + 1) begin
                query_count = n;
                #1; check();
            end
        end
        cycle(1, 1, CAPACITY - 1, CAPACITY);
        cycle(0, 0, 0, CAPACITY);
        // 重复覆盖不能被误认为多写一行；乱序和复位均不能混入上一批。
        for (n = 0; n < 12000; n = n + 1) begin
            cycle((n % 229) == 0, ($random(seed) & 3) != 0,
                ($random(seed) & 32'h7fffffff) % (CAPACITY + 3),
                ($random(seed) & 32'h7fffffff) % (CAPACITY + 3));
            if (n % 997 == 0) begin
                @(negedge clk); rst_n = 0;
                @(negedge clk); rst_n = 1;
            end
        end
        cycle(1, 0, 0, 0);
        cycle(0, 1, 0, 1);
        cycle(0, 0, 0, 1);
        if (!complete) $fatal(1, "Single-row prefix rejected");
        $display("Tracker fixture capacity=%0d comparisons=%0d", CAPACITY, checks);
        finished = 1;
    end
endmodule

module tb_score_upload_tracker;
    wire [4:0] done;
    score_tracker_fixture #(.CAPACITY(1), .SEED(1)) one(done[0]);
    score_tracker_fixture #(.CAPACITY(4), .SEED(37)) tiny(done[1]);
    score_tracker_fixture #(.CAPACITY(17), .SEED(197)) partial_group(done[2]);
    score_tracker_fixture #(.CAPACITY(32), .SEED(732)) two_groups(done[3]);
    score_tracker_fixture #(.CAPACITY(1024), .SEED(123456789)) board_capacity(done[4]);
    initial begin
        wait (&done);
        $display("SCORE UPLOAD TRACKER PASS");
        $finish;
    end
    initial begin #2000000; $fatal(1, "Tracker timeout"); end
endmodule
