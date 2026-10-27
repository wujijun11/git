// 四区两级菜单：短触后松手执行；左端长按进入总菜单。
// position 沿用 MPR121 位置单位 0..3072。长按和防抖以系统时钟计数。
// 总菜单四区：音色、音区、录放、曲谱；请求受反压时保持完整负载。
module slider_menu_controller #(
    parameter integer CLK_HZ = 49152000,
    parameter integer DEBOUNCE_CYCLES = CLK_HZ / 50,
    parameter integer LONG_PRESS_CYCLES = CLK_HZ,
    parameter integer HYSTERESIS = 48,
    // 默认关闭以兼容既有四区菜单；完整板级顶层显式开启。
    parameter integer PERFORMANCE_ENABLE = 0,
    parameter integer ROOT_IDLE_CYCLES = CLK_HZ * 5,
    parameter integer PERFORMANCE_MENU_EDGE = 128
) (
    input wire clk, rst_n,
    input wire touch_active,
    input wire touch_fault, // 采集失效不等于松手：取消当前手势，禁止误执行。
    input wire [11:0] position,
    output reg request_valid,
    input wire request_ready,
    output reg [1:0] request_kind, // 0=子动作，1=进入子页面，2=总菜单，3=回音量
    output reg [1:0] request_page, request_zone,
    output reg main_menu,
    output reg [1:0] page, selected_zone,
    output wire [1:0] preview_zone,
    input wire action_busy,
    output reg performance_mode,
    output wire volume_position_valid,
    output wire [11:0] volume_position
);
    localparam integer DB = DEBOUNCE_CYCLES > 0 ? DEBOUNCE_CYCLES : 1;
    localparam integer LP = LONG_PRESS_CYCLES > 0 ? LONG_PRESS_CYCLES : 1;
    localparam integer CW = $clog2(LP + DB + 2) > 0 ? $clog2(LP + DB + 2) : 1;
    reg previous_active, blocked_touch, long_fired, stable_touch;
    reg [1:0] candidate;
    reg [CW-1:0] stable_count, long_count;
    localparam integer IDLE_LIMIT = ROOT_IDLE_CYCLES > 0 ? ROOT_IDLE_CYCLES : 1;
    localparam integer IW = $clog2(IDLE_LIMIT + 1) > 0 ? $clog2(IDLE_LIMIT + 1) : 1;
    reg [IW-1:0] idle_count;
    reg performance_menu_candidate, volume_release_valid;
    reg [11:0] last_touch_position;
    // 在最左端起始的触摸先保留为菜单手势；拖出保护区后才按音量处理。
    // 其他位置开始的连续滑动可回到0，不会在调小音量时意外打开菜单。
    assign volume_position_valid = PERFORMANCE_ENABLE && !touch_fault &&
        (volume_release_valid || (performance_mode && touch_active && stable_touch &&
         !blocked_touch && !long_fired && !performance_menu_candidate));
    assign volume_position = volume_release_valid ? last_touch_position : position;
    wire space = !request_valid || request_ready;
    wire [1:0] raw_zone = position < 768 ? 2'd0 :
        position < 1536 ? 2'd1 : position < 2304 ? 2'd2 : 2'd3;
    // 相邻分区留回差，避免手指停在边界时来回改变候选项。
    // 每个分区边界均为常数，直接比较可避免工具将“分区编号×768”推成DSP。
    // 与原有边界回差等价；HYSTERESIS是0..767的位置单位，不是毫秒。
    localparam integer LOW1 = HYSTERESIS < 768 ? 768 - HYSTERESIS : 0;
    localparam integer LOW2 = HYSTERESIS < 1536 ? 1536 - HYSTERESIS : 0;
    localparam integer LOW3 = HYSTERESIS < 2304 ? 2304 - HYSTERESIS : 0;
    wire in_candidate = candidate == 0 ? position < 768 + HYSTERESIS :
        candidate == 1 ? position >= LOW1 && position < 1536 + HYSTERESIS :
        candidate == 2 ? position >= LOW2 && position < 2304 + HYSTERESIS :
        position >= LOW3;
    wire [1:0] tracked_zone = in_candidate ? candidate : raw_zone;
    assign preview_zone = touch_active ? candidate : selected_zone;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            request_valid <= 0;
            request_kind <= 0;
            request_page <= 0;
            request_zone <= 0;
            main_menu <= 0;
            page <= 0;
            selected_zone <= 0;
            previous_active <= 0;
            blocked_touch <= 0;
            long_fired <= 0;
            stable_touch <= 0;
            candidate <= 0;
            stable_count <= 0;
            long_count <= 0;
            performance_mode <= PERFORMANCE_ENABLE != 0;
            idle_count <= 0;
            performance_menu_candidate <= 0;
            volume_release_valid <= 0;
            last_touch_position <= 0;
        end else begin
            volume_release_valid <= 0;
            previous_active <= touch_active;
            if (touch_active && !touch_fault)
                last_touch_position <= position;
            if (request_valid && request_ready)
                request_valid <= 0;

            // 仅总菜单超时；子页面即使闲置很久也必须长按返回。
            // ROOT_IDLE_CYCLES=0供OLED空闲波形入口使用：显示超时由覆盖层处理，菜单状态保留。
            if (ROOT_IDLE_CYCLES <= 0 || !PERFORMANCE_ENABLE || performance_mode || !main_menu ||
                touch_active || touch_fault || request_valid || action_busy) begin
                idle_count <= 0;
            end else if (idle_count >= IDLE_LIMIT - 1) begin
                performance_mode <= 1;
                main_menu <= 0;
                idle_count <= 0;
                stable_touch <= 0;
            end else idle_count <= idle_count + 1'b1;

            if (touch_fault) begin
                previous_active <= 0;
                blocked_touch <= 1;
                stable_touch <= 0;
                long_fired <= 0;
                stable_count <= 0;
                long_count <= 0;
            end else if (touch_active && !previous_active) begin
                candidate <= raw_zone;
                stable_count <= 0;
                long_count <= 0;
                stable_touch <= 0;
                long_fired <= 0;
                // 一项待执行动作未取走时，忽略整次新触摸，不能覆盖旧请求。
                blocked_touch <= !space;
                performance_menu_candidate <= position <= PERFORMANCE_MENU_EDGE;
            end else if (touch_active && !blocked_touch && !long_fired) begin
                if (PERFORMANCE_ENABLE && performance_mode) begin
                    // 音量滑动跨四区不重新防抖；只在新触摸开始时等待位置稳定。
                    if (!stable_touch) begin
                        performance_menu_candidate <= position <= PERFORMANCE_MENU_EDGE;
                        if (stable_count >= DB - 1) begin
                            stable_touch <= 1;
                            long_count <= 0;
                        end else stable_count <= stable_count + 1'b1;
                    end else if (performance_menu_candidate) begin
                        if (position > PERFORMANCE_MENU_EDGE + HYSTERESIS) begin
                            performance_menu_candidate <= 0;
                            long_count <= 0;
                        end else if (long_count >= LP - 1 && space) begin
                            performance_mode <= 0;
                            main_menu <= 1;
                            long_fired <= 1;
                            request_valid <= 1;
                            request_kind <= 2;
                            request_page <= page;
                            request_zone <= 0;
                        end else if (long_count < LP - 1)
                            long_count <= long_count + 1'b1;
                    end
                end else if (tracked_zone != candidate) begin
                    candidate <= tracked_zone;
                    stable_count <= 0;
                    long_count <= 0;
                    stable_touch <= 0;
                end else if (!stable_touch) begin
                    if (stable_count >= DB - 1) begin
                        stable_touch <= 1;
                        long_count <= 0;
                    end else stable_count <= stable_count + 1'b1;
                end else if (candidate == 0 || (PERFORMANCE_ENABLE && candidate == 3)) begin
                    if (long_count >= LP - 1 && space) begin
                        main_menu <= !(PERFORMANCE_ENABLE && candidate == 3);
                        if (PERFORMANCE_ENABLE && candidate == 3)
                            performance_mode <= 1;
                        long_fired <= 1;
                        request_valid <= 1;
                        request_kind <= (PERFORMANCE_ENABLE && candidate == 3) ? 2'd3 : 2'd2;
                        request_page <= page;
                        request_zone <= 0;
                    end else if (long_count < LP - 1)
                        long_count <= long_count + 1'b1;
                end
            end

            if (!touch_fault && !touch_active && previous_active) begin
                // 长按进入总菜单后必须先松手，不能同次触摸又选中第一项。
                if (!blocked_touch && !long_fired && stable_touch && space) begin
                    if (PERFORMANCE_ENABLE && performance_mode) begin
                        // 短触左端允许在松手时设置低音量，长按菜单则没有这次提交。
                        volume_release_valid <= 1;
                    end else begin
                        request_valid <= 1;
                        request_zone <= candidate;
                        selected_zone <= candidate;
                        if (main_menu) begin
                            page <= candidate;
                            main_menu <= 0;
                            request_kind <= 1;
                            request_page <= candidate;
                        end else begin
                            request_kind <= 0;
                            request_page <= page;
                        end
                    end
                end
                blocked_touch <= 0;
                stable_touch <= 0;
                stable_count <= 0;
                long_count <= 0;
            end
        end
    end
endmodule
