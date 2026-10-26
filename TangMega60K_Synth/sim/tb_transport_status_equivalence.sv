`timescale 1ns/1ps
// 穷举动作编号、忙状态、曲谱/录音有效性并注入高位格式错误。
// 参考为已交付OLED版，强制内部状态仅用于组合译码等价；实际握手另由集成回归检查。
module tb_transport_status_equivalence;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0;
    reg [79:0] payload=0;
    integer fixture=0;
    wire [15:0] actual, expected;
    genvar g;
    generate for(g=0;g<2;g=g+1) begin: settings
        performance_controller #(.SCORE_CAPACITY(4),.RECORD_CAPACITY(4),
            .DIRECT_SCORE_ENABLE(1),.LEARNING_ENABLE(g)) candidate(
            .clk(clk),.rst_n(rst_n),.command_valid(1'b0),.command_opcode(8'd4),
            .command_payload(payload),.local_action_status(actual[g*8+:8]),
            .record_valid(1'b0),.event_ready(1'b0),.record_read_index(16'd0),
            .learning_touch_mask(25'd0),.learning_touch_ready(1'b0));
        performance_controller_timing_reference #(.SCORE_CAPACITY(4),.RECORD_CAPACITY(4),
            .DIRECT_SCORE_ENABLE(1),.LEARNING_ENABLE(g)) reference_model(
            .clk(clk),.rst_n(rst_n),.command_valid(1'b0),.command_opcode(8'd4),
            .command_payload(payload),.local_action_status(expected[g*8+:8]),
            .record_valid(1'b0),.event_ready(1'b0),.record_read_index(16'd0),
            .learning_touch_mask(25'd0),.learning_touch_ready(1'b0));
        initial begin
            force candidate.playing=fixture[0]; force reference_model.playing=fixture[0];
            force candidate.recording=fixture[1]; force reference_model.recording=fixture[1];
            force candidate.timed_guide_active=fixture[2]; force reference_model.timed_guide_active=fixture[2];
            force candidate.stopping=fixture[3]; force reference_model.stopping=fixture[3];
            force candidate.event_valid=fixture[4]; force reference_model.event_valid=fixture[4];
            force candidate.committed_count=fixture[5] ? 16'd0:16'd4;
            force reference_model.committed_count=fixture[5] ? 16'd0:16'd4;
            force candidate.selected_direct=fixture[6]; force reference_model.selected_direct=fixture[6];
            force candidate.record_count=fixture[7] ? 16'd1:16'd0;
            force reference_model.record_count=fixture[7] ? 16'd1:16'd0;
            force candidate.unsupported_record_source=fixture[8];
            force reference_model.unsupported_record_source=fixture[8];
        end
    end endgenerate
    integer action, checked=0;
    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        for(fixture=0;fixture<512;fixture=fixture+1) begin
            for(action=0;action<256;action=action+1) begin
                payload=action;
                #1;
                if(actual !== expected) $fatal(1,"transport status differs fixture=%d action=%d",fixture,action);
                payload[8+(fixture%72)]=1;
                #1;
                if(actual !== expected) $fatal(1,"malformed transport status differs");
                checked=checked+4;
            end
        end
        $display("TRANSPORT STATUS EQUIVALENCE PASS %d comparisons with learning enabled/disabled",checked);
        $finish;
    end
    initial begin #300000;$fatal(1,"transport status equivalence timeout");end
endmodule
