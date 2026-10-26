// 曲谱命令的一拍寄存边界：接收后固定来源和负载，在后端执行同拍才给来源ready。
// 不提前ACK，不丢弃/重复命令；把UART/本地仲裁与大规模RAM完整性校验分开。
module performance_command_stage (
    input wire clk, rst_n,
    input wire remote_valid, output wire remote_ready,
    input wire [7:0] remote_opcode, input wire [79:0] remote_payload,
    input wire local_valid, output wire local_ready, input wire [7:0] local_action,
    output wire [7:0] local_status,
    output wire command_valid, input wire command_ready,
    output reg [7:0] command_opcode, output reg [79:0] command_payload,
    input wire [7:0] command_status
);
    reg pending, owner_remote;
    assign command_valid=rst_n && pending;
    assign remote_ready=command_valid && owner_remote && command_ready;
    assign local_ready=command_valid && !owner_remote && command_ready;
    assign local_status=command_status;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pending<=0;
            owner_remote<=0;
            command_opcode<=0;
            command_payload<=0;
        end else if(pending) begin
            if(command_ready)pending<=0;
        end else if(remote_valid) begin
            pending<=1;
            owner_remote<=1;
            command_opcode<=remote_opcode;
            command_payload<=remote_payload;
        end else if(local_valid) begin
            pending<=1;
            owner_remote<=0;
            command_opcode<=8'h04;
            command_payload<={72'd0,local_action};
        end
    end
endmodule
