`timescale 1ns/1ps
// OLED接入触发时序修正后的功能回归：用已知旋律核对内置曲谱行缓存。
// 仅把毫秒基准加速为一拍；音符顺序、反压和TRANSPORT状态仍使用生产RTL。
module tb_oled_timing_regression;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg command_valid = 0;
    reg [7:0] command_opcode = 0;
    reg [79:0] command_payload = 0;
    wire command_ready;
    wire [7:0] command_status, local_action_status;
    wire event_valid, event_on, playing;
    reg event_ready = 0;
    wire [5:0] event_source;
    wire [6:0] event_note, event_velocity;
    wire [1:0] event_timbre;
    reg [174:0] mapping;
    performance_controller #(.CLK_HZ(1000), .SCORE_CAPACITY(32), .RECORD_CAPACITY(32)) dut (
        .clk(clk), .rst_n(rst_n),
        .command_valid(command_valid), .command_ready(command_ready),
        .command_opcode(command_opcode), .command_payload(command_payload),
        .command_status(command_status), .local_action_status(local_action_status),
        .record_valid(1'b0), .record_on(1'b0), .record_source(6'd0),
        .record_note(7'd0), .record_velocity(7'd0), .record_timbre(2'd0),
        .event_valid(event_valid), .event_ready(event_ready), .event_on(event_on),
        .event_source(event_source), .event_note(event_note),
        .event_velocity(event_velocity), .event_timbre(event_timbre),
        .key_map_flat(mapping), .current_timbre(2'd2),
        .learning_touch_mask(25'd0), .learning_touch_ready(1'b0),
        .playing(playing), .record_read_index(16'd0)
    );

    integer melody [0:15];
    integer accepted = 0;
    integer cycles = 0;
    reg stalled = 0;
    reg [22:0] held_payload;
    wire [22:0] payload = {event_on, event_source, event_note, event_velocity, event_timbre};
    always @(negedge clk) begin
        cycles = cycles + 1;
        // 连续20拍反压，随后12拍可接收，覆盖行首等待和稳定保持。
        event_ready = (cycles % 32) >= 20;
    end
    always @(posedge clk) begin
        if (rst_n) begin
            if (stalled && (!event_valid || payload !== held_payload))
                $fatal(1, "builtin event changed under backpressure");
            stalled <= event_valid && !event_ready;
            held_payload <= payload;
            if (event_valid && event_ready) begin
                if (accepted >= 32) $fatal(1, "duplicate builtin event");
                if (event_source !== melody[accepted / 2] ||
                    event_note !== 60 + melody[accepted / 2] ||
                    event_on !== ((accepted % 2) == 0) ||
                    event_velocity !== (((accepted % 2) == 0) ? 100 : 0) ||
                    event_timbre !== 2)
                    $fatal(1, "builtin event %d incorrect: %h", accepted, payload);
                accepted = accepted + 1;
            end
        end else stalled <= 0;
    end

    initial begin
        for (integer key = 0; key < 25; key = key + 1) mapping[key * 7 +: 7] = 60 + key;
        melody[0] = 4; melody[1] = 4; melody[2] = 5; melody[3] = 7;
        melody[4] = 7; melody[5] = 5; melody[6] = 4; melody[7] = 2;
        melody[8] = 0; melody[9] = 0; melody[10] = 2; melody[11] = 4;
        melody[12] = 4; melody[13] = 2; melody[14] = 2; melody[15] = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        // 上传提交的“缺行”错误不能污染独立TRANSPORT状态。
        command_opcode = 7;
        command_payload = 1;
        @(negedge clk);
        if (command_status !== 1 || local_action_status !== 0)
            $fatal(1, "local TRANSPORT status inherited commit validation");
        command_opcode = 4;
        command_valid = 1;
        @(negedge clk);
        command_valid = 0;
        wait (accepted == 32 && !playing);
        repeat (100) @(negedge clk);
        if (dut.held != 0 || accepted != 32 || dut.score_position != 32)
            $fatal(1, "builtin completion/ownership incorrect");
        $display("OLED TIMING REGRESSION PASS 32 builtin events, stalls, release ownership and local status separation");
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "builtin timing regression timeout accepted=%d", accepted);
    end
endmodule
