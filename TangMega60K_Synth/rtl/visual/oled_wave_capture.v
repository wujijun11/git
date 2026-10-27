// 捕获实际I2S左声道PCM：每4个48kHz样本形成一列，共128列，时间窗10.667ms。
// 两个128x12位区轮换，OLED整帧读取期间前台保持；显示从不反压音频。
module oled_wave_capture #(
    parameter integer PCM_SHIFT = 15 // 仅显示缩放；每32768 PCM单位约1像素
) (
    input wire clk,
    input wire rst_n,
    input wire sample_valid,
    input wire signed [23:0] sample,
    input wire frame_snapshot,
    input wire [6:0] read_column,
    output reg [11:0] read_bounds
);
    reg [11:0] bounds [0:255];
    reg front_bank;
    reg write_bank;
    reg front_valid;
    reg capture_complete;
    reg [6:0] write_column;
    reg [1:0] sub_sample;
    reg [5:0] column_top;
    reg [5:0] column_bottom;
    reg [5:0] previous_y;
    reg read_valid;
    reg [11:0] memory_read;

    function [5:0] sample_y;
        input signed [23:0] value;
        reg signed [23:0] scaled;
        reg signed [24:0] y;
        begin
            scaled = value >>> PCM_SHIFT;
            if (scaled > 22)
                sample_y = 6'd2;
            else if (scaled < -22)
                sample_y = 6'd46;
            else begin
                y = 25'sd24 - scaled;
                sample_y = y[5:0];
            end
        end
    endfunction
    wire [5:0] y_now = sample_y(sample);
    // 把相邻列交界样本也纳入区间，使线段连续；极值来自实际PCM。
    wire [5:0] first_top = write_column != 0 && previous_y < y_now ? previous_y : y_now;
    wire [5:0] first_bottom = write_column != 0 && previous_y > y_now ? previous_y : y_now;
    wire [5:0] next_top = sub_sample == 0 ? first_top :
        (y_now < column_top ? y_now : column_top);
    wire [5:0] next_bottom = sub_sample == 0 ? first_bottom :
        (y_now > column_bottom ? y_now : column_bottom);
    wire swap_frame = frame_snapshot && capture_complete;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            front_bank <= 0;
            write_bank <= 1;
            front_valid <= 0;
            capture_complete <= 0;
            write_column <= 0;
            sub_sample <= 0;
            column_top <= 24;
            column_bottom <= 24;
            previous_y <= 24;
        end else if (swap_frame) begin
            front_bank <= write_bank;
            write_bank <= front_bank;
            front_valid <= 1;
            capture_complete <= 0;
            write_column <= 0;
            sub_sample <= 0;
        end else if (sample_valid && !capture_complete) begin
            previous_y <= y_now;
            column_top <= next_top;
            column_bottom <= next_bottom;
            sub_sample <= sub_sample + 1'b1;
            if (sub_sample == 3) begin
                if (write_column == 127)
                    capture_complete <= 1;
                else
                    write_column <= write_column + 1'b1;
            end
        end
    end
    // RAM不做全体复位，保持同步块RAM推断；无有效前台时输出零电平线。
    always @(posedge clk) begin
        if (rst_n && !swap_frame && sample_valid && !capture_complete && sub_sample == 3)
            bounds[{write_bank, write_column}] <= {next_top, next_bottom};
        memory_read <= bounds[{front_bank, read_column}];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            read_valid <= 0;
        else
            read_valid <= front_valid;
    end
    always @* begin
        read_bounds = read_valid ? memory_read : {6'd24, 6'd24};
    end
endmodule
