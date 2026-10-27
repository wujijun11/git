// 顶部16像素留给原模式标题；下方48像素绘制真实采样区间与虚线零电平。
// page_q/column_q与捕获RAM的一拍同步读延迟对齐。
module oled_wave_renderer (
    input wire clk,
    input wire [2:0] screen_page,
    input wire [6:0] column,
    input wire [11:0] bounds,
    output reg [7:0] data
);
    reg [2:0] page_q;
    reg [6:0] column_q;
    integer bit_index;
    integer row;
    always @(posedge clk) begin
        page_q <= screen_page;
        column_q <= column;
    end
    always @* begin
        data = 0;
        row = 0;
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            row = (page_q - 2) * 8 + bit_index;
            if (page_q >= 2 && row >= bounds[11:6] && row <= bounds[5:0])
                data[bit_index] = 1;
            if (page_q >= 2 && row == 24 && column_q[2:0] == 0)
                data[bit_index] = 1;
        end
    end
endmodule
