// 四区两级菜单：短触后松手执行；左端长按进入总菜单。
// position 沿用 MPR121 位置单位 0..3072。长按和防抖以系统时钟计数。
// 总菜单四区：音色、音区、录放、曲谱；请求受反压时保持完整负载。
module slider_menu_controller #(
    parameter integer CLK_HZ = 49152000,
    parameter integer DEBOUNCE_CYCLES = CLK_HZ / 50,
    parameter integer LONG_PRESS_CYCLES = CLK_HZ,
    parameter integer HYSTERESIS = 48
) (
    input wire clk, rst_n,
    input wire touch_active,
    input wire touch_fault, // 采集失效不等于松手：取消当前手势，禁止误执行。
    input wire [11:0] position,
    output reg request_valid,
    input wire request_ready,
    output reg [1:0] request_kind, // 0=子动作，1=进入子页面，2=进入总菜单
    output reg [1:0] request_page, request_zone,
    output reg main_menu,
    output reg [1:0] page, selected_zone,
    output wire [1:0] preview_zone
);
    localparam integer DB = DEBOUNCE_CYCLES > 0 ? DEBOUNCE_CYCLES : 1;
    localparam integer LP = LONG_PRESS_CYCLES > 0 ? LONG_PRESS_CYCLES : 1;
    localparam integer CW = $clog2(LP + DB + 2) > 0 ? $clog2(LP + DB + 2) : 1;
    reg previous_active, blocked_touch, long_fired, stable_touch;
    reg [1:0] candidate;
    reg [CW-1:0] stable_count, long_count;
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
        end else begin
            previous_active <= touch_active;
            if (request_valid && request_ready)
                request_valid <= 0;

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
            end else if (touch_active && !blocked_touch && !long_fired) begin
                if (tracked_zone != candidate) begin
                    candidate <= tracked_zone;
                    stable_count <= 0;
                    long_count <= 0;
                    stable_touch <= 0;
                end else if (!stable_touch) begin
                    if (stable_count >= DB - 1) begin
                        stable_touch <= 1;
                        long_count <= 0;
                    end else stable_count <= stable_count + 1'b1;
                end else if (candidate == 0) begin
                    if (long_count >= LP - 1 && space) begin
                        main_menu <= 1;
                        long_fired <= 1;
                        request_valid <= 1;
                        request_kind <= 2;
                        request_page <= page;
                        request_zone <= 0;
                    end else if (long_count < LP - 1)
                        long_count <= long_count + 1'b1;
                end
            end

            if (!touch_fault && !touch_active && previous_active) begin
                // 长按进入总菜单后必须先松手，不能同次触摸又选中第一项。
                if (!blocked_touch && !long_fired && stable_touch && space) begin
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
                blocked_touch <= 0;
                stable_touch <= 0;
                stable_count <= 0;
                long_count <= 0;
            end
        end
    end
endmodule
