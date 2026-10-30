// 开关式延音：位于既有分配器和音源之间，不改变公共V2端口。
// note-off被确认后，分配器将该键标为已松开，但槽位仍占用直到音源done。
// 重复同音可使用另一个空闲槽，最多仍为VOICE_COUNT；不偷取正在发声的声部。
module sustain_command_gate #(
    parameter integer VOICE_COUNT = 64,
    parameter integer ID_WIDTH = 6
) (
    input wire clk, rst_n,
    input wire sustain_enabled,
    input wire in_valid,
    output wire in_ready,
    input wire in_on,
    input wire [ID_WIDTH-1:0] in_voice,
    input wire [6:0] in_note, in_velocity,
    input wire [1:0] in_timbre,
    output wire out_valid,
    input wire out_ready,
    output reg out_on,
    output reg [ID_WIDTH-1:0] out_voice,
    output reg [6:0] out_note, out_velocity,
    output reg [1:0] out_timbre,
    output reg [VOICE_COUNT-1:0] deferred_mask,
    output reg [ID_WIDTH:0] deferred_count
);
    localparam IDLE=0, FORWARD=1, DEFER=2, SCAN=3, RELEASE=4;
    reg [2:0] state;
    reg [ID_WIDTH-1:0] scan_voice;

    // 已向音源呈现的命令由寄存器冻结，不能因踏板切换或反压而撤回。
    // 普通命令只有音源真正接受时才向原分配器确认，不提前改变声部所有权。
    assign out_valid = rst_n && (state==FORWARD || state==RELEASE);
    assign in_ready = rst_n && (state==DEFER || (state==FORWARD && out_ready));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            scan_voice <= 0;
            out_on <= 0;
            out_voice <= 0;
            out_note <= 0;
            out_velocity <= 0;
            out_timbre <= 0;
            deferred_mask <= 0;
            deferred_count <= 0;
        end else begin
            case (state)
                IDLE: begin
                    if (!sustain_enabled && |deferred_mask) begin
                        scan_voice <= 0;
                        state <= SCAN;
                    end else if (in_valid) begin
                        out_on <= in_on;
                        out_voice <= in_voice;
                        out_note <= in_note;
                        out_velocity <= in_velocity;
                        out_timbre <= in_timbre;
                        state <= !in_on && sustain_enabled ? DEFER : FORWARD;
                    end
                end
                FORWARD: if (out_ready) begin
                    if (deferred_mask[out_voice]) begin
                        deferred_mask[out_voice] <= 0;
                        deferred_count <= deferred_count - 1'b1;
                    end
                    state <= IDLE;
                end
                DEFER: if (in_valid) begin
                    if (!deferred_mask[out_voice]) begin
                        deferred_mask[out_voice] <= 1;
                        deferred_count <= deferred_count + 1'b1;
                    end
                    state <= IDLE;
                end
                SCAN: begin
                    // 逐槽扫描，避免增加64路优先编码长路径。释放期间暂缓新命令。
                    // 极快地重新开启延音可保留尚未呈现的尾音；已呈现OFF继续完成。
                    if (sustain_enabled) state <= IDLE;
                    else if (deferred_mask[scan_voice]) begin
                        out_on <= 0;
                        out_voice <= scan_voice;
                        out_note <= 0;
                        out_velocity <= 0;
                        out_timbre <= 0;
                        state <= RELEASE;
                    end else if (scan_voice==VOICE_COUNT-1) state <= IDLE;
                    else scan_voice <= scan_voice + 1'b1;
                end
                RELEASE: if (out_ready) begin
                    deferred_mask[out_voice] <= 0;
                    deferred_count <= deferred_count - 1'b1;
                    if (scan_voice==VOICE_COUNT-1) state <= IDLE;
                    else begin
                        scan_voice <= scan_voice + 1'b1;
                        state <= SCAN;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
