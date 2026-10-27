// 临时上板诊断：在独立50MHz域观察既有状态快照，不接入任何功能ready/reset。
// 不保存历史、不使用块RAM；heartbeat为已有音频域计数器经双级采样后的单比特。
module audio_boot_status #(
    parameter integer HEARTBEAT_TIMEOUT_CYCLES = 5000000 // 50MHz下100ms
) (
    input wire clk,
    input wire [47:0] snapshot,
    output reg [23:0] status_grb
);
    localparam integer AGE_WIDTH = $clog2(HEARTBEAT_TIMEOUT_CYCLES + 1);
    reg previous_heartbeat = 0;
    reg heartbeat_seen = 0;
    reg [AGE_WIDTH-1:0] heartbeat_age = 0;
    wire board_ready = snapshot[0];
    wire audio_locked = snapshot[1];
    wire ready_sync = snapshot[2];
    wire system_rst_n = snapshot[3];
    wire audio_rst_n = snapshot[4];
    wire heartbeat = snapshot[44];
    wire running = heartbeat_seen && heartbeat_age < HEARTBEAT_TIMEOUT_CYCLES;

    always @(posedge clk) begin
        previous_heartbeat <= heartbeat;
        if (!board_ready) begin
            heartbeat_seen <= 0;
            heartbeat_age <= 0;
        end else if (heartbeat != previous_heartbeat) begin
            heartbeat_seen <= 1;
            heartbeat_age <= 0;
        end else if (heartbeat_age < HEARTBEAT_TIMEOUT_CYCLES) begin
            heartbeat_age <= heartbeat_age + 1'b1;
        end
    end

    // 数值为GRB：绿、红、蓝各8位。优先显示公共启动链，再显示传感器状态。
    always @* begin
        if (!board_ready)
            status_grb = 24'h080808; // 白：50MHz板级上电等待
        else if (!audio_locked)
            status_grb = 24'h002000; // 红：两级音频PLL尚未完成锁定资格确认
        else if (!running)
            status_grb = 24'h000020; // 蓝：未见音频心跳，或心跳停止超过100ms
        else if (!ready_sync || !system_rst_n)
            status_grb = 24'h002020; // 紫红：音频在跑，但顶层仍处于复位
        else if (!audio_rst_n)
            status_grb = 24'h202000; // 黄：音频通路被panic/传感器溢出复位
        else if (snapshot[18:16] != 3'b111 || snapshot[21:19] != 0)
            status_grb = 24'h200020; // 青：公共启动链正常，传感器未就绪/有故障
        else
            status_grb = 24'h200000; // 绿：时钟、复位与传感器就绪；不代表UART已验收
    end
endmodule
