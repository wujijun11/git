`timescale 1ns/1ps
// 模式回传是只读快照：反压、重试及复位不允许篡改或触发演奏动作。
module tb_mode_status;
    reg clk=0; always #5 clk=~clk;
    reg rn=0,cv=0,rr=0; reg [7:0] seq=1; reg [79:0] cp=2;
    reg [79:0] status=80'h000000000c0203012001;
    wire cr,rv,ev,xv,pv,panic; wire [7:0] rs,ro; wire [79:0] rp;
    remote_command_router #(.ENABLE_MODE_STATUS(1)) dut(
        .clk(clk),.rst_n(rn),.cmd_valid(cv),.cmd_ready(cr),.cmd_seq(seq),.cmd_opcode(8'h08),.cmd_payload(cp),
        .rsp_valid(rv),.rsp_ready(rr),.rsp_seq(rs),.rsp_opcode(ro),.rsp_payload(rp),
        .event_valid(ev),.event_ready(1'b1),.expr_valid(xv),.expr_ready(1'b1),
        .performance_valid(pv),.performance_ready(1'b1),.performance_status(8'd0),.panic_pulse(panic),
        .active_count(7'd0),.playing(1'b0),.recording(1'b0),.guide_active(1'b0),
        .overflow_sticky(1'b0),.record_count(16'd0),.score_position(16'd0),.underrun_count(32'd0),
        .mode_status_payload(status),.record_read_valid(1'b0),.record_read_payload(80'd0));
    task cycles(input integer n); repeat(n)@(negedge clk); endtask
    task query(input [7:0] s,input [79:0] payload,input [7:0] result,input [79:0] expected);
        begin
            @(negedge clk);seq=s;cp=payload;cv=1;
            do @(posedge clk);while(!cr);
            @(negedge clk);cv=0;
            wait(rv);cycles(2);
            if(ro!==8'h80||rp[15:8]!==result)$fatal(1,"ACK mismatch");
            rr=1;cycles(1);rr=0;
            if(result==0)begin
                wait(rv && ro==8'h83);cycles(2);
                if(rp!==expected)$fatal(1,"snapshot mismatch");
                status=~status;cycles(10);
                if(!rv || rp!==expected)$fatal(1,"stalled mode state changed");
                rr=1;cycles(1);rr=0;
            end
            cycles(3);
        end
    endtask
    always @(posedge clk)if(rn && (ev||xv||pv||panic))$fatal(1,"read-only request caused action");
    initial begin
        cycles(4);rn=1;cycles(4);
        query(1,2,0,80'h000000000c0203012001);
        // 相同序号重试仍返回上次快照；新序号才捕获新值。
        query(1,2,0,80'h000000000c0203012001);
        status=80'h00000000e80200002201;
        query(2,2,0,80'h00000000e80200002201);
        query(3,258,1,0);
        query(4,3,1,0);
        rn=0;cycles(2);rn=1;status=80'd1;cycles(2);
        query(1,2,0,80'd1);
        $display("MODE STATUS PASS snapshot, backpressure, duplicate, reset, strict selector, read-only");$finish;
    end
    initial begin #100000;$fatal(1,"mode status timeout");end
endmodule
