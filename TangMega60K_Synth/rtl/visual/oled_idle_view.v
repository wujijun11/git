// OLED空闲覆盖层：只选择显示内容，不改变滑条菜单状态或消费触摸事件。
module oled_idle_view #(
    parameter integer IDLE_CYCLES = 147456000 // 49.152MHz下3秒
) (
    input wire clk,
    input wire rst_n,
    input wire touch_active,
    input wire busy,
    input wire [7:0] error,
    input wire [13:0] ui_signature,
    output reg waveform_view
);
    localparam integer LIMIT = IDLE_CYCLES > 0 ? IDLE_CYCLES : 1;
    localparam integer CW = $clog2(LIMIT + 1) > 0 ? $clog2(LIMIT + 1) : 1;
    reg [CW-1:0] idle_count;
    reg [13:0] previous_ui;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idle_count <= 0;
            previous_ui <= 0;
            waveform_view <= 0;
        end else begin
            previous_ui <= ui_signature;
            if (touch_active || busy || error != 0 || ui_signature != previous_ui) begin
                idle_count <= 0;
                waveform_view <= 0;
            end else if (idle_count >= LIMIT - 1) begin
                waveform_view <= 1;
            end else begin
                idle_count <= idle_count + 1'b1;
            end
        end
    end
endmodule
