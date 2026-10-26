// 上传曲谱完整性跟踪：逐行位图 + 每16行一个同步完成标志。
// count/index单位是事件行，范围由CAPACITY限定；不存储PCM或曲谱负载。
// 分组完成标志与行位图在同一沿更新，不增加提交等待拍或改变ACK状态码。
module score_upload_tracker #(
    parameter integer CAPACITY = 1024
)(
    input wire clk, rst_n,
    input wire clear,
    input wire write_valid,
    input wire [15:0] write_index,
    input wire [15:0] query_count,
    output wire complete,
    output reg [CAPACITY-1:0] row_written
);
    localparam integer GROUP_SIZE = 16;
    localparam integer GROUPS = (CAPACITY + GROUP_SIZE - 1) / GROUP_SIZE;
    localparam integer AW = CAPACITY > 1 ? $clog2(CAPACITY) : 1;
    wire legal_write = write_valid && write_index < CAPACITY;
    reg [GROUPS-1:0] group_complete;
    wire [GROUPS-1:0] query_group_ok;
    wire [GROUP_SIZE-1:0] write_mask, unused_tail;

    genvar bit_index, group_index;
    generate for (bit_index = 0; bit_index < GROUP_SIZE; bit_index = bit_index + 1) begin: masks
        assign write_mask[bit_index] = write_index[3:0] == bit_index;
        assign unused_tail[bit_index] = query_count[3:0] <= bit_index;
    end endgenerate

    always @(posedge clk) begin
        if (!rst_n)
            row_written <= 0;
        else begin
            // 与旧协议一致：清上一批与写下一批同拍时，新写入的那一行保留。
            if (clear)
                row_written <= 0;
            if (legal_write)
                row_written[write_index[AW-1:0]] <= 1'b1;
        end
    end

    generate for (group_index = 0; group_index < GROUPS; group_index = group_index + 1) begin: groups
        localparam integer BASE = group_index * GROUP_SIZE;
        localparam integer END = BASE + GROUP_SIZE < CAPACITY ? BASE + GROUP_SIZE : CAPACITY;
        wire [GROUP_SIZE-1:0] bits_written, after_clear;
        wire selected_write = legal_write && (write_index >> 4) == group_index;
        for (bit_index = 0; bit_index < GROUP_SIZE; bit_index = bit_index + 1) begin: bits_in_group
            if (BASE + bit_index < CAPACITY) begin: present
                assign bits_written[bit_index] = row_written[BASE + bit_index];
                assign after_clear[bit_index] = 1'b0;
            end else begin: padding
                // 最后一组不足16行时，填充值为1，不要求不存在的行被上传。
                assign bits_written[bit_index] = 1'b1;
                assign after_clear[bit_index] = 1'b1;
            end
        end

        always @(posedge clk) begin
            if (!rst_n)
                group_complete[group_index] <= 1'b0;
            else if (clear || selected_write)
                group_complete[group_index] <= &((clear ? after_clear : bits_written) |
                    (selected_write ? write_mask : 16'd0));
        end

        // 已完整要求的组只读取寄存标志；最多一个末组需要现场检查16个位。
        // 高位行数不再为1024行各做一次比较，并减少完整性归约的组合深度。
        assign query_group_ok[group_index] = query_count <= BASE ? 1'b1 :
            query_count >= END ? group_complete[group_index] :
            &(bits_written | unused_tail);
    end endgenerate

    assign complete = !clear && (&query_group_ok);
endmodule
