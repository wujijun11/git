`timescale 1ns/1ps
// 人工控制状态快照，验证诊断灯判定及心跳停转检测；不代表真实PLL启动测试。
module tb_audio_boot_status;
    reg clk = 0;
    always #10 clk = ~clk;
    reg [47:0] snapshot = 0;
    reg heartbeat_enabled = 0;
    wire [23:0] color;
    audio_boot_status #(.HEARTBEAT_TIMEOUT_CYCLES(8)) dut (
        .clk(clk), .snapshot(snapshot), .status_grb(color)
    );
    always @(negedge clk) begin
        if (heartbeat_enabled)
            snapshot[44] = ~snapshot[44];
    end
    task expect_color(input [23:0] expected);
        begin
            repeat (2) @(posedge clk);
            #1;
            if (color !== expected)
                $fatal(1, "color=%h expected=%h", color, expected);
        end
    endtask
    initial begin
        expect_color(24'h080808);
        snapshot[0] = 1;
        expect_color(24'h002000);
        snapshot[1] = 1;
        expect_color(24'h000020);
        heartbeat_enabled = 1;
        expect_color(24'h002020);
        snapshot[3:2] = 2'b11;
        expect_color(24'h202000);
        snapshot[4] = 1;
        expect_color(24'h200020);
        snapshot[18:16] = 3'b111;
        expect_color(24'h200000);
        snapshot[19] = 1;
        expect_color(24'h200020);
        snapshot[19] = 0;
        expect_color(24'h200000);
        heartbeat_enabled = 0;
        repeat (10) @(posedge clk);
        expect_color(24'h000020);
        snapshot[1] = 0;
        expect_color(24'h002000);
        snapshot[1] = 1;
        heartbeat_enabled = 1;
        expect_color(24'h200000);
        snapshot[0] = 0;
        expect_color(24'h080808);
        $display("AUDIO BOOT STATUS PASS color priority, heartbeat loss and recovery");
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "diagnostic unit timeout");
    end
endmodule
