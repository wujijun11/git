// 实体25键等候学习。复用曲谱RAM的顺序读口，不生成音频，不保存第二份曲谱。
// 同一时间戳(delta_ms=0)的有效NoteOn组成一组；时长不考核。
// 每组必须先全部松键，再准确按住整组(不能多按)，避免长按跨过重复音。
module learning_stepper (
    input wire clk, input wire rst_n,
    input wire start, input wire stop,
    input wire row_valid, output wire row_ready,
    input wire [4:0] row_key, input wire row_on,
    input wire [31:0] row_delta_ms, input wire row_last,
    input wire [24:0] touch_mask, input wire touch_ready,
    output wire active, output reg [24:0] target_mask,
    output wire waiting_release, output wire waiting_press,
    output reg [15:0] completed_steps, output reg finished
);
    localparam IDLE=0, COLLECT=1, RELEASE=2, PRESS=3;
    reg [1:0] state;
    reg [24:0] collected;
    reg last_group;
    wire boundary = row_valid && collected!=0 && row_delta_ms!=0;
    wire [24:0] next_collected = collected | ((row_on && row_key<25) ? (25'd1 << row_key) : 25'd0);
    assign active = state!=IDLE;
    assign waiting_release = state==RELEASE;
    assign waiting_press = state==PRESS;
    // 边界行不消费；下一组开始后重新处理，因此NoteOff/首个NoteOn不会丢失。
    assign row_ready = state==COLLECT && !boundary && !start && !stop;

    always @(posedge clk) begin
        if (!rst_n) begin
            state<=IDLE; collected<=0; target_mask<=0; last_group<=0;
            completed_steps<=0; finished<=0;
        end else if (stop) begin
            state<=IDLE; collected<=0; target_mask<=0; finished<=0;
        end else if (start) begin
            state<=COLLECT; collected<=0; target_mask<=0; last_group<=0;
            completed_steps<=0; finished<=0;
        end else case (state)
            COLLECT: if (boundary) begin
                target_mask<=collected; collected<=0; last_group<=0; state<=RELEASE;
            end else if (row_valid && row_ready) begin
                collected<=next_collected;
                if (row_last) begin
                    collected<=0;
                    if (next_collected!=0) begin
                        target_mask<=next_collected; last_group<=1; state<=RELEASE;
                    end else begin state<=IDLE; target_mask<=0; finished<=1; end
                end
            end
            RELEASE: if (touch_ready && touch_mask==0) state<=PRESS;
            PRESS: begin
                // 传感器重连后必须重新松开；故障不能被当成一次正确按键。
                if (!touch_ready) state<=RELEASE;
                else if (touch_mask==target_mask) begin
                    completed_steps<=completed_steps+16'd1; target_mask<=0;
                    if (last_group) begin state<=IDLE; finished<=1; end
                    else state<=COLLECT;
                end
            end
            default: ;
        endcase
    end
endmodule
