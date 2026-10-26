// 板载按键和菜单动作共享原有本地动作入口。锁住受反压的授权，负载不跳变。
module local_action_arbiter (
    input wire clk, rst_n,
    input wire key_valid, output wire key_ready, input wire [7:0] key_action,
    input wire menu_valid, output wire menu_ready, input wire [7:0] menu_action,
    output wire out_valid, input wire out_ready, output wire [7:0] out_action,
    output wire selected_menu
);
    reg locked, grant, turn;
    wire choice = locked ? grant : (menu_valid && (!key_valid || turn));
    assign selected_menu = choice;
    assign out_valid = rst_n && (choice ? menu_valid : key_valid);
    assign out_action = choice ? menu_action : key_action;
    // 空闲时也给当前授权方ready，保留原板载动作入口的握手语义。
    assign key_ready = rst_n && out_ready && !choice;
    assign menu_ready = rst_n && out_ready && choice;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            locked <= 0;
            grant <= 0;
            turn <= 0;
        end else if (out_valid) begin
            if (out_ready) begin
                locked <= 0;
                turn <= !choice;
            end else begin
                locked <= 1;
                grant <= choice;
            end
        end
    end
endmodule
