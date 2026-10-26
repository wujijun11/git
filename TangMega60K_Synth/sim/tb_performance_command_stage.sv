`timescale 1ns/1ps
// 命令寄存边界：所有ready代表后端执行，不能代表提前排队成功。
module tb_performance_command_stage;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,remote_valid=0,local_valid=0,command_ready=0;
    reg [7:0] remote_opcode=6,local_action=5,command_status=0;
    reg [79:0] remote_payload=80'h123456789;
    wire remote_ready,local_ready,command_valid;
    wire [7:0] local_status,command_opcode;wire [79:0] command_payload;
    performance_command_stage dut(.*);
    integer accepted=0;
    always @(posedge clk)if(rst_n && command_valid && command_ready)accepted=accepted+1;
    task cycles(input integer n);repeat(n)@(negedge clk);endtask
    initial begin
        cycles(3);rst_n=1;cycles(2);
        remote_valid=1;local_valid=1;cycles(1);
        if(!command_valid || remote_ready || local_ready || command_opcode!=6 || command_payload!=80'h123456789)
            $fatal(1,"premature ready or wrong remote priority");
        cycles(8);if(command_payload!=80'h123456789 || !command_valid)$fatal(1,"stalled payload changed");
        command_ready=1;#1;if(!remote_ready || local_ready)$fatal(1,"remote ownership lost");
        cycles(1);remote_valid=0;command_ready=0;
        cycles(1);if(!command_valid || command_opcode!=4 || command_payload!=5)$fatal(1,"local request missing");
        remote_valid=1;remote_opcode=7;remote_payload=80'h20040;
        cycles(3);if(command_opcode!=4 || command_payload!=5)$fatal(1,"remote preempted pending local");
        command_status=2;command_ready=1;#1;
        if(!local_ready || remote_ready || local_status!=2)$fatal(1,"local result not propagated");
        cycles(1);local_valid=0;command_ready=0;command_status=0;
        cycles(1);if(command_opcode!=7 || command_payload!=80'h20040)$fatal(1,"next remote missing");
        rst_n=0;cycles(2);rst_n=1;remote_valid=0;cycles(3);
        if(command_valid || remote_ready || local_ready || accepted!=2)$fatal(1,"reset or duplicate execution");
        $display("PERFORMANCE COMMAND STAGE PASS no early ACK, remote/local priority, stable backpressure, result, no preemption, reset");$finish;
    end
    initial begin #10000;$fatal(1,"command stage timeout");end
endmodule
