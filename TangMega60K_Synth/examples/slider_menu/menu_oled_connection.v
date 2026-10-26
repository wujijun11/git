// 接入片段：输入来自instrument_full_system同名状态输出，clk使用49.152MHz。
// oled_scl/oled_sda应由队长核对空闲3.3V GPIO后在板级顶层和CST中分配。
// 此示例没有猜测任何板卡引脚，不可直接作为可下载工程使用。
module menu_oled_connection (
    input wire clk,rst_n,menu_main,
    input wire [1:0] menu_page,menu_zone,
    input wire recording,playing,guide_active,menu_busy,
    input wire [7:0] menu_error,
    input wire [15:0] menu_record_count,
    inout wire oled_scl,oled_sda,
    output wire oled_fault
);
    oled_status_display display(
        .clk(clk),.rst_n(rst_n),.main_menu(menu_main),.menu_page(menu_page),.zone(menu_zone),
        .recording(recording),.playing(playing),.guide(guide_active),.busy(menu_busy),
        .error(menu_error),.record_count(menu_record_count),
        .scl(oled_scl),.sda(oled_sda),.fault(oled_fault),.completed_frames());
endmodule
