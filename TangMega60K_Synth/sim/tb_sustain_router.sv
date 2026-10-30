`timescale 1ns/1ps
// 新配置只在合法事务提交；反压和相同seq重试不能重复写开关。
module tb_sustain_router;
    reg clk=0;always #5 clk=~clk;
    reg rn=0,cv=0,rr=0;
    reg [7:0] seq=0,op=3;
    reg [79:0] cp=0,status=80'h400101;
    wire cr,rv,write_pulse,value;
    wire [7:0] ro,rs;wire [79:0] rp;
    remote_command_router #(.ENABLE_SUSTAIN(1)) dut(
        .clk(clk),.rst_n(rn),.cmd_valid(cv),.cmd_ready(cr),.cmd_seq(seq),.cmd_opcode(op),.cmd_payload(cp),
        .rsp_valid(rv),.rsp_ready(rr),.rsp_seq(rs),.rsp_opcode(ro),.rsp_payload(rp),
        .event_ready(1'b1),.expr_ready(1'b1),.performance_ready(1'b1),.performance_status(8'd0),
        .active_count(7'd0),.playing(1'b0),.recording(1'b0),.guide_active(1'b0),
        .overflow_sticky(1'b0),.record_count(16'd0),.score_position(16'd0),.underrun_count(32'd0),
        .mode_status_payload(80'd0),.learning_status_payload(80'd0),.sustain_status_payload(status),
        .record_read_valid(1'b0),.record_read_payload(80'd0),
        .sustain_write_pulse(write_pulse),.sustain_value(value));
    integer writes=0;
    always @(posedge clk)if(rn && write_pulse)writes=writes+1;
    task cycles(input integer n);repeat(n)@(negedge clk);endtask
    task transaction(input integer number,code,input [79:0] data,input integer expected,input bit has_data);
        reg [79:0] snapshot;
        begin
            snapshot=status;
            @(negedge clk);seq=number;op=code;cp=data;cv=1;
            do @(posedge clk);while(!cr);
            @(negedge clk);cv=0;
            wait(rv);cycles(3);
            if(rs!=number || ro!=128 || rp[15:8]!=expected)$fatal(1,"sustain router ACK");
            cycles(12);if(ro!=128 || rp[15:8]!=expected)$fatal(1,"ACK moved during stall");
            rr=1;cycles(1);rr=0;
            if(has_data)begin
                wait(rv && ro==134);cycles(2);
                // 第二次同序号读回也必须返回原事务快照。
                if(rp!=80'h400101)$fatal(1,"sustain snapshot changed");
                status=80'h400001;cycles(12);
                if(rp!=80'h400101)$fatal(1,"status data moved during stall");
                rr=1;cycles(1);rr=0;
            end
            cycles(2);
        end
    endtask
    initial begin
        cycles(3);rn=1;
        transaction(0,3,80'h0102,0,0);
        if(writes!=1 || !value)$fatal(1,"valid pedal write");
        transaction(0,3,80'h0102,0,0);
        transaction(0,3,80'h0002,1,0);
        transaction(1,3,80'h0202,1,0);
        if(writes!=1)$fatal(1,"invalid/retried command wrote pedal twice");
        transaction(2,8,80'd5,0,1);
        transaction(2,8,80'd5,0,1);
        transaction(3,8,80'h0105,1,0);
        transaction(4,3,80'h0002,0,0);
        if(writes!=2 || value)$fatal(1,"pedal off missing");
        $display("SUSTAIN ROUTER PASS writes=%0d",writes);$finish;
    end
    initial begin #2000000;$fatal(1,"sustain router timeout");end
endmodule
