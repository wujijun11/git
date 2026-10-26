// 单级弹性事件寄存器：将仲裁结果与来源标签整包锁存，切断跨模块组合长路径。
// WIDTH=25时负载为{selected[1:0],on,source[5:0],note[6:0],velocity[6:0],timbre[1:0]}。
// 时钟域不变，空闲时增加一拍延迟；连续流可每拍一条，反压时保持整包稳定。
// 异步复位丢弃未完成事务，和音源/FIFO的全局停止复位边界保持一致。
module note_event_pipeline #(
    parameter integer WIDTH = 25
)(
    input wire clk, rst_n,
    input wire in_valid,
    output wire in_ready,
    input wire [WIDTH-1:0] in_payload,
    output wire out_valid,
    input wire out_ready,
    output wire [WIDTH-1:0] out_payload
);
    reg valid;
    reg [WIDTH-1:0] payload;
    assign in_ready = rst_n && (!valid || out_ready);
    assign out_valid = rst_n && valid;
    assign out_payload = payload;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid <= 1'b0;
            payload <= 0;
        end else if (in_ready) begin
            valid <= in_valid;
            if (in_valid)
                payload <= in_payload;
        end
    end
endmodule
