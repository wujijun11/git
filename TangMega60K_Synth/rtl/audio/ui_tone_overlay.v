// 菜单短提示音：正弦DDS逐样本生成两音提示，绝不读取录音PCM。
// 只在PCM输入握手时推进相位和包络；不占用/抢夺64个演奏声部。
// 左右叠加同一个小幅提示音，使用25位中间结果并饱和到24位。
module ui_tone_overlay #(
    parameter SINE_FILE="rtl/audio/rom/sine.hex"
) (
    input wire clk,rst_n,
    input wire prompt_valid,input wire [1:0] prompt_code,
    input wire in_valid,output wire in_ready,
    input wire signed [23:0] in_left,in_right,
    output reg out_valid,input wire out_ready,
    output reg signed [23:0] out_left,out_right
);
    reg signed [15:0] sine[0:1023];
    initial $readmemh(SINE_FILE,sine);
    reg pending,active,calculate;
    reg [1:0] pending_code,active_code;
    reg [12:0] age;
    reg [31:0] phase;
    reg signed [15:0] sine_sample;
    reg [7:0] env_latched;
    reg signed [23:0] left_latched,right_latched;
    wire second_note=age>=2176;
    wire sounding=active && (age<2048 || (age>=2176 && age<4224));
    wire [11:0] segment_age=second_note ? age-13'd2176 : age[11:0];
    wire [7:0] envelope=!sounding ? 8'd0 : segment_age<128 ?
        {segment_age[6:0],1'b0} : segment_age>=1920 ?
        {~segment_age[6:0],1'b0} : 8'd255;
    reg [31:0] step;
    // FTW=round(f*2^32/48000)，使用C5/E5/G5/C6等固定提示音。
    always @* begin
        case(active_code)
            0:step=second_note ? 32'd58987262 : 32'd46819718;
            1:step=second_note ? 32'd70152933 : 32'd58987262;
            2:step=second_note ? 32'd93639436 : 32'd70152933;
            default:step=second_note ? 32'd46819718 : 32'd93639436;
        endcase
    end
    wire signed [24:0] product=$signed(sine_sample)*$signed({1'b0,env_latched});
    wire signed [24:0] beep=product>>>5;
    wire signed [24:0] sum_left=$signed({left_latched[23],left_latched})+beep;
    wire signed [24:0] sum_right=$signed({right_latched[23],right_latched})+beep;
    function [23:0] saturate;
        input signed [24:0] value;
        begin
            if(value>25'sd8388607)saturate=24'h7fffff;
            else if(value< -25'sd8388608)saturate=24'h800000;
            else saturate=value[23:0];
        end
    endfunction
    assign in_ready=rst_n && !calculate && (!out_valid || out_ready);
    always @(posedge clk) begin
        if(in_valid && in_ready)sine_sample<=sine[phase[31:22]];
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            pending<=0;active<=0;calculate<=0;
            pending_code<=0;active_code<=0;age<=0;phase<=0;
            env_latched<=0;left_latched<=0;right_latched<=0;
            out_valid<=0;out_left<=0;out_right<=0;
        end else begin
            if(out_valid && out_ready)out_valid<=0;
            if(calculate)begin
                out_left<=saturate(sum_left);out_right<=saturate(sum_right);
                out_valid<=1;calculate<=0;
            end
            if(in_valid && in_ready)begin
                left_latched<=in_left;right_latched<=in_right;
                env_latched<=envelope;calculate<=1;
                if(!active && pending)begin
                    active<=1;active_code<=pending_code;age<=0;phase<=0;pending<=0;
                end else if(active)begin
                    if(age==4223)begin active<=0;age<=0;phase<=0;end
                    else begin
                        age<=age+1'b1;
                        phase<=age==2175 ? 32'd0 : phase+step;
                    end
                end
            end
            // 快速菜单操作只保留最新待提示状态，队列容量固定，不阻塞演奏。
            if(prompt_valid)begin pending<=1;pending_code<=prompt_code;end
        end
    end
endmodule
