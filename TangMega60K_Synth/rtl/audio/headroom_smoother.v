// 自动混音余量跨档平滑，保持原1/2/4/.../64倍稳态标度。
// target_shift有效范围0～6，active_count有效范围0～64。
// 每个start处理一帧；目标保持不变时，最多64帧到达目标。
// 连续48kHz下为1.333ms。反压期间没有start，斜坡也不推进。
module headroom_smoother (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire [6:0] active_count,
    input wire [2:0] target_shift,
    input wire signed [31:0] mix_left,
    input wire signed [31:0] mix_right,
    output wire signed [31:0] scaled_left,
    output wire signed [31:0] scaled_right,
    output reg [16:0] applied_gain_q10,
    output wire peak_guard
);
    reg initialized;
    reg product_valid;
    reg product_pending;
    reg pending_empty;
    reg [16:0] target_q10;
    reg [16:0] step_q10;

    // Q10增益：1024表示1倍，65536表示64倍；17位保存无符号正数。
    wire [16:0] target = 17'd1024 << target_shift;
    wire [16:0] distance = target > applied_gain_q10 ?
        target - applied_gain_q10 : applied_gain_q10 - target;
    wire [16:0] next_step = target != target_q10 ?
        (distance + 17'd63) >> 6 : step_q10;
    reg [16:0] next_gain;

    always @* begin
        if (!initialized)
            next_gain = target;
        else if (applied_gain_q10 < target)
            next_gain = distance <= next_step ? target : applied_gain_q10 + next_step;
        else if (applied_gain_q10 > target)
            next_gain = distance <= next_step ? target : applied_gain_q10 - next_step;
        else
            next_gain = target;
    end

    // 32位混音乘以补0后的18位有符号增益，完整保留50位乘积。
    reg signed [49:0] product_l;
    reg signed [49:0] product_r;
    wire signed [49:0] rounded_l = (product_l + 50'sd512) >>> 10;
    wire signed [49:0] rounded_r = (product_r + 50'sd512) >>> 10;

    // 下降斜坡期间可能暂时超过原瞬时档位的安全边界，因此先宽位判断再钳位。
    // 边界来自64路16位有符号样本相干叠加；触发时有非线性失真，详见实现说明。
    function signed [31:0] bound_mix;
        input signed [49:0] value;
        begin
            if (value > 50'sd2097088)
                bound_mix = 32'sd2097088; // 64*32767
            else if (value < -50'sd2097152)
                bound_mix = -32'sd2097152; // 64*(-32768)
            else
                bound_mix = value[31:0];
        end
    endfunction
    assign scaled_left = product_valid ? bound_mix(rounded_l) : 32'sd0;
    assign scaled_right = product_valid ? bound_mix(rounded_r) : 32'sd0;
    assign peak_guard = product_valid && (
        rounded_l > 50'sd2097088 || rounded_l < -50'sd2097152 ||
        rounded_r > 50'sd2097088 || rounded_r < -50'sd2097152
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            initialized <= 0;
            product_valid <= 0;
            product_pending <= 0;
            pending_empty <= 1;
            applied_gain_q10 <= 1024;
            target_q10 <= 1024;
            step_q10 <= 0;
        end else begin
            product_pending <= start;
            if (product_pending)
                product_valid <= 1;
            if (start) begin
                pending_empty <= active_count == 0;
                if (active_count == 0) begin
                    // 真正无声部才重新武装，释放尾音仍参与计数。
                    // 下一次首音直接采用原档位，保留首音响度。
                    initialized <= 0;
                    applied_gain_q10 <= 1024;
                    target_q10 <= 1024;
                    step_q10 <= 0;
                end else begin
                    initialized <= 1;
                    applied_gain_q10 <= next_gain;
                    target_q10 <= target;
                    step_q10 <= next_step;
                end
            end
        end
    end
    // start在最后V_MIX边沿寄存增益，该边沿混音器同时加入最后声部。
    // 下一V_WRITE边沿使用更新后的混音和已寄存增益，MASTER仍按原拍次执行。
    // 独立接入时，mix须在start后一拍乘积采集前保持稳定。
    // 大乘积寄存器无需异步复位，product_valid在复位时屏蔽无效值，降低复位扇出。
    always @(posedge clk) begin
        if (product_pending) begin
            product_l <= pending_empty ? 50'sd0 : mix_left * $signed({1'b0, applied_gain_q10});
            product_r <= pending_empty ? 50'sd0 : mix_right * $signed({1'b0, applied_gain_q10});
        end
    end
endmodule
