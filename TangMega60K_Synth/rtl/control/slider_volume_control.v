// 滑条位置 -> V2音量目标。这里只生成控制参数，实际音频增益/平滑仍由原音源完成。
// 位置0..3072映射Q1.11增益0..2048，100%等于原有中性增益，不额外放大。
// 已呈现的valid/负载在反压时保持；仅合并尚未呈现的连续位置，始终保留最新目标。
module slider_volume_control #(
    parameter integer GAIN_HYSTERESIS = 4
)(
    input wire clk, rst_n,
    input wire position_valid,
    input wire [11:0] position,
    output reg expr_valid,
    input wire expr_ready,
    output reg [11:0] expr_gain
);
    reg sampled_valid, previous_valid;
    reg [21:0] scaled_position;
    reg force_sample, sampled_new_touch;
    reg [11:0] last_observed, desired_gain;
    reg desired_dirty;
    wire [21:0] clamped_position = position > 3072 ? 22'd3072 : {10'd0, position};
    // 683/1024约等于2/3；四舍五入并限制端点，最大误差1个Q1.11单位。
    // 显式移位相加，避免为固定比例映射推断新的DSP或除法器。
    wire [21:0] scaled = (clamped_position << 9) + (clamped_position << 7) +
        (clamped_position << 5) + (clamped_position << 3) +
        (clamped_position << 1) + clamped_position;
    wire [12:0] rounded_gain = (scaled_position + 22'd512) >> 10;
    wire [11:0] mapped_gain = rounded_gain > 2048 ? 12'd2048 : rounded_gain[11:0];
    wire [11:0] gain_distance = mapped_gain >= last_observed ?
        mapped_gain - last_observed : last_observed - mapped_gain;
    wire changed = sampled_valid && (sampled_new_touch || force_sample ||
        gain_distance >= GAIN_HYSTERESIS ||
        ((mapped_gain == 0 || mapped_gain == 2048) && mapped_gain != last_observed));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sampled_valid <= 0;
            previous_valid <= 0;
            scaled_position <= 0;
            sampled_new_touch <= 0;
            force_sample <= 1;
            last_observed <= 2048;
            desired_gain <= 2048;
            desired_dirty <= 0;
            expr_valid <= 0;
            expr_gain <= 2048;
        end else begin
            sampled_valid <= position_valid;
            previous_valid <= position_valid;
            sampled_new_touch <= position_valid && !previous_valid;
            if (position_valid)
                scaled_position <= scaled;
            if (!position_valid)
                force_sample <= 1;
            if (!expr_valid || expr_ready) begin
                expr_valid <= desired_dirty;
                if (desired_dirty)
                    expr_gain <= desired_gain;
                desired_dirty <= 0;
            end
            if (changed) begin
                last_observed <= mapped_gain;
                desired_gain <= mapped_gain;
                desired_dirty <= 1;
                force_sample <= 0;
            end
        end
    end
endmodule
