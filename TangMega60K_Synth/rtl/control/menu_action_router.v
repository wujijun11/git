// 子页面动作映射。复用performance_controller原动作，不产生音频或新协议。
// 开始录制/回放前先停旧任务；忙状态分时重试，不能锁住其他本地停止动作。
module menu_action_router #(
    parameter integer CLK_HZ = 49152000,
    parameter integer RETRY_CYCLES = CLK_HZ / 1000,
    parameter integer MAX_RETRIES = 250
) (
    input wire clk, rst_n,
    input wire request_valid, output wire request_ready,
    input wire [1:0] request_kind, request_page, request_zone,
    input wire recording, playing, guide_active,
    output reg timbre_valid, output reg [1:0] timbre,
    output reg signed [6:0] transpose,
    output wire action_valid, input wire action_ready,
    output wire [7:0] action, input wire [7:0] action_status,
    output reg prompt_valid, output reg [1:0] prompt_code,
    output reg [7:0] last_error,
    output wire busy
);
    localparam IDLE = 0, ISSUE = 1, BACKOFF = 2;
    reg [1:0] state;
    reg [7:0] target_action, current_action;
    reg [1:0] step;
    reg [7:0] retries;
    localparam integer RW = $clog2(RETRY_CYCLES + 1) > 0 ? $clog2(RETRY_CYCLES + 1) : 1;
    reg [RW-1:0] retry_timer;
    wire start_request = target_action == 1 || target_action == 2 ||
                         target_action == 6 || target_action == 8;
    reg [7:0] decoded_action;
    always @* begin
        if (request_page == 2) begin
            case (request_zone)
                0: decoded_action = 2;
                1: decoded_action = 3;
                2: decoded_action = 8;
                default: decoded_action = 5;
            endcase
        end else begin
            case (request_zone)
                0: decoded_action = 1;
                1: decoded_action = 0;
                2: decoded_action = 6;
                default: decoded_action = 7;
            endcase
        end
    end
    assign request_ready = rst_n && state == IDLE;
    assign busy = state != IDLE;
    assign action_valid = rst_n && state == ISSUE;
    assign action = current_action;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            timbre_valid <= 0;
            timbre <= 2;
            transpose <= 0;
            prompt_valid <= 0;
            prompt_code <= 0;
            last_error <= 0;
            target_action <= 0;
            current_action <= 0;
            step <= 0;
            retries <= 0;
            retry_timer <= 0;
        end else begin
            timbre_valid <= 0;
            prompt_valid <= 0;
            case (state)
                IDLE: if (request_valid) begin
                    last_error <= 0;
                    retries <= 0;
                    if (request_kind != 0) begin
                        prompt_valid <= 1;
                        prompt_code <= request_kind == 2 ? 2'd3 : request_page;
                    end else if (request_page == 0) begin
                        timbre_valid <= 1;
                        case (request_zone)
                            0: timbre <= 2;
                            1: timbre <= 1;
                            2: timbre <= 0;
                            default: timbre <= 3;
                        endcase
                        prompt_valid <= 1;
                        prompt_code <= request_zone;
                    end else if (request_page == 1) begin
                        case (request_zone)
                            0: transpose <= -7'sd24;
                            1: transpose <= -7'sd12;
                            2: transpose <= 0;
                            default: transpose <= 7'sd12;
                        endcase
                        prompt_valid <= 1;
                        prompt_code <= request_zone;
                    end else if (request_page == 2 && request_zone == 0 && recording) begin
                        // 正在录制时再次点“开始”不清空已经录下的内容。
                        prompt_valid <= 1;
                        prompt_code <= 0;
                    end else begin
                        target_action <= decoded_action;
                        // step0停录音，step1停播放，step2执行目标；全部经同一握手。
                        if ((decoded_action == 1 || decoded_action == 2 ||
                             decoded_action == 6 || decoded_action == 8) && recording) begin
                            current_action <= 3;
                            step <= 0;
                        end else if ((decoded_action == 1 || decoded_action == 2 ||
                                      decoded_action == 6 || decoded_action == 8) &&
                                     (playing || guide_active)) begin
                            current_action <= 0;
                            step <= 1;
                        end else begin
                            current_action <= decoded_action;
                            step <= 2;
                        end
                        state <= ISSUE;
                    end
                end
                ISSUE: if (action_ready) begin
                    if (action_status == 2 && retries < MAX_RETRIES) begin
                        retries <= retries + 1'b1;
                        retry_timer <= 0;
                        state <= BACKOFF;
                    end else if (action_status != 0) begin
                        last_error <= action_status;
                        prompt_valid <= 1;
                        prompt_code <= 3;
                        state <= IDLE;
                    end else if (step == 0 && start_request && (playing || guide_active)) begin
                        current_action <= 0;
                        step <= 1;
                        retries <= 0;
                    end else if (step < 2) begin
                        current_action <= target_action;
                        step <= 2;
                        retries <= 0;
                    end else begin
                        prompt_valid <= 1;
                        prompt_code <= 0;
                        state <= IDLE;
                    end
                end
                BACKOFF: begin
                    if (retry_timer >= RETRY_CYCLES - 1) state <= ISSUE;
                    else retry_timer <= retry_timer + 1'b1;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
