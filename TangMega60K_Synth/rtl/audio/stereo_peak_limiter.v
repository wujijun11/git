// 逐帧立体声联动峰值限幅：不根据声部数量改变增益。
// 输入是尚未截断的45位主混音，输出24位PCM；低于阈值且增益为1时逐位直通。
// 超限帧用16次二进制小数除法计算floor(CEILING/peak * 65536)，不引入除法器IP/新时钟。
// 增益即时下降、每个已接收帧最多恢复RELEASE_STEP_Q16，反压时不重复处理同一帧。
module stereo_peak_limiter #(
    parameter integer CEILING=4194303, // 约-6dBFS，为后级音效保留余量；原单声部中性标度不变
    parameter integer RELEASE_STEP_Q16=64 // 最多1024帧从0恢复到1，48kHz下21.33ms
)(
    input wire clk,rst_n,
    input wire in_valid,
    output wire in_ready,
    input wire signed [44:0] in_left,in_right,
    output reg out_valid,
    input wire out_ready,
    output reg signed [23:0] out_left,out_right,
    output reg [16:0] applied_gain_q16,
    output reg limiting
);
    localparam [2:0] IDLE=0,DIVIDE=1,SELECT_GAIN=2,MULTIPLY=3,ROUND=4,HOLD=5;
    localparam [16:0] UNITY=17'd65536;
    reg [2:0] state;
    reg signed [44:0] held_left,held_right;
    reg [44:0] denominator;
    reg [45:0] remainder;
    reg [15:0] quotient;
    reg [4:0] remaining_bits;
    reg [16:0] required_gain;
    reg signed [62:0] product_left,product_right;
    wire [44:0] magnitude_left=in_left[44]?-in_left:in_left;
    wire [44:0] magnitude_right=in_right[44]?-in_right:in_right;
    wire [44:0] peak=magnitude_left>magnitude_right?magnitude_left:magnitude_right;
    wire [45:0] doubled_remainder=remainder<<1;
    wire quotient_bit=doubled_remainder>={1'b0,denominator};
    wire [15:0] next_quotient={quotient[14:0],quotient_bit};
    wire [17:0] recovering_gain={1'b0,applied_gain_q16}+RELEASE_STEP_Q16;
    wire [16:0] release_gain=recovering_gain>65536?UNITY:recovering_gain[16:0];
    wire [16:0] selected_gain=required_gain<release_gain?required_gain:release_gain;
    wire signed [62:0] rounded_left=(product_left+63'sd32768)>>>16;
    wire signed [62:0] rounded_right=(product_right+63'sd32768)>>>16;
    assign in_ready=state==IDLE && !out_valid;

    // 正常算术已保证不超过阈值；末级钳位作为数值防护，不做位宽截断回绕。
    function [23:0] bounded;
        input signed [62:0] value;
        begin
            if(value>CEILING)
                bounded=CEILING;
            else if(value< -CEILING)
                bounded=-CEILING;
            else
                bounded=value[23:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;
            held_left<=0;
            held_right<=0;
            denominator<=0;
            remainder<=0;
            quotient<=0;
            remaining_bits<=0;
            required_gain<=UNITY;
            applied_gain_q16<=UNITY;
            limiting<=0;
            out_valid<=0;
            out_left<=0;
            out_right<=0;
        end else begin
            case(state)
                IDLE:if(in_valid && in_ready)begin
                    held_left<=in_left;
                    held_right<=in_right;
                    if(peak>CEILING)begin
                        denominator<=peak;
                        remainder<=CEILING;
                        quotient<=0;
                        remaining_bits<=16;
                        state<=DIVIDE;
                    end else begin
                        required_gain<=UNITY;
                        state<=SELECT_GAIN;
                    end
                end
                DIVIDE:begin
                    remainder<=quotient_bit?doubled_remainder-{1'b0,denominator}:doubled_remainder;
                    quotient<=next_quotient;
                    remaining_bits<=remaining_bits-1'b1;
                    if(remaining_bits==1)begin
                        // 超出正常混音范围的极端输入也不使用零增益，交由末级钳位兜底。
                        required_gain<=next_quotient==0?17'd1:{1'b0,next_quotient};
                        state<=SELECT_GAIN;
                    end
                end
                SELECT_GAIN:begin
                    applied_gain_q16<=selected_gain;
                    limiting<=selected_gain!=UNITY;
                    state<=MULTIPLY;
                end
                MULTIPLY:state<=ROUND;
                ROUND:begin
                    out_left<=bounded(rounded_left);
                    out_right<=bounded(rounded_right);
                    out_valid<=1;
                    state<=HOLD;
                end
                HOLD:if(out_valid && out_ready)begin
                    out_valid<=0;
                    state<=IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end
    // DSP大数据寄存器由状态有效性屏蔽，不增加异步复位扇出。
    always @(posedge clk)begin
        if(state==MULTIPLY)begin
            product_left<=held_left*$signed({1'b0,applied_gain_q16});
            product_right<=held_right*$signed({1'b0,applied_gain_q16});
        end
    end
endmodule
