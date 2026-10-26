// 将已提交的Q1.11 gain转换为OLED百分比；2048=100%，4095约为200%。
// 只观察参数，不反馈到音频ready、增益或时钟链路。
module gain_percent_meter (
    input wire clk, rst_n,
    input wire [11:0] gain,
    output reg [7:0] percent
);
    reg [18:0] scaled;
    wire [18:0] extended = {7'd0,gain};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scaled <= 19'd204800;
            percent <= 100;
        end else begin
            scaled <= (extended << 6) + (extended << 5) + (extended << 2);
            percent <= (scaled + 19'd1024) >> 11;
        end
    end
endmodule
