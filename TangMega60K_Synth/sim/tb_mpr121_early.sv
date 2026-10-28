`timescale 1ns/1ps
// 使用真实串行总线验证提前状态邮箱，不直接强制RTL内部信号。
module tb_mpr121_early;
    reg clk=0;
    always #5 clk=~clk;
    reg resetn=0,irq_n=0,early_key_ready=0;
    wire snapshot_valid,ready,fault,early_key_valid;
    wire [343:0] snapshot;
    wire [11:0] early_key_status;
    wire [3:0] last_error;
    wire [31:0] error_count,last_success_age;
    wire [4:0] init_stage;
    wire [15:0] oor_status;
    tri1 scl,sda;
    reg hold_scl=0;
    integer accepted=0,full_count=0,read_count=0;
    time early_time,full_time;
    mpr121_sampler #(.CLK_HZ(4000000),.I2C_HZ(400000),.TIMEOUT_CYCLES(10000),
        .RESET_CYCLES(10),.SETTLE_CYCLES(100),.POLL_CYCLES(40),.RETRY_CYCLES(200),
        .CALIBRATION_SNAPSHOTS(1),.MAX_RETRIES(0),.EARLY_KEY_ENABLE(1)) dut(
        .clk(clk),.resetn(resetn),.irq_n(irq_n),.snapshot_ready(1'b1),
        .snapshot_valid(snapshot_valid),.snapshot(snapshot),.ready(ready),.fault(fault),
        .last_error(last_error),.error_count(error_count),.last_success_age(last_success_age),
        .init_stage(init_stage),.oor_status(oor_status),.scl(scl),.sda(sda),
        .early_key_valid(early_key_valid),.early_key_ready(early_key_ready),.early_key_status(early_key_status));
    mpr121_bus_model model(clk,scl,sda,2'd0,1'b0,hold_scl,1'b0);
    always @(posedge clk)if(resetn)begin
        if(early_key_valid && early_key_ready)accepted=accepted+1;
        if(snapshot_valid)full_count=full_count+1;
    end
    task restart;
        begin
            @(negedge clk);resetn=0;hold_scl=0;early_key_ready=0;model.set_touches(0);
            repeat(5)@(negedge clk);
            resetn=1;
            wait(ready);
            // 校准快照不得提前当成演奏事件。
            if(early_key_valid)$fatal(1,"calibration published early key");
        end
    endtask
    task expect_status(input [11:0] expected);
        begin
            wait(early_key_valid);
            @(negedge clk);
            if(early_key_status!==expected)$fatal(1,"early status expected=%h got=%h",expected,early_key_status);
        end
    endtask
    initial begin
        $timeformat(-9,0,"",0); // %t按ns打印；避免默认ps再误标为ns。
        restart();
        model.set_touches(12'h805);
        expect_status(12'h805);early_time=$time;
        if(!dut.bus_busy || snapshot_valid)$fatal(1,"early publication waited for complete snapshot");
        wait(snapshot_valid);full_time=$time;
        if(snapshot[11:0]!=12'h805 || full_time-early_time<30000)
            $fatal(1,"full snapshot lost or early path did not save bus time");
        // 邮箱反压时，完整事务已完成，不能用后续状态覆盖尚未消费的按下。
        read_count=model.reads;
        model.set_touches(0);
        repeat(7000)begin
            @(negedge clk);
            if(!early_key_valid || early_key_status!=12'h805 || model.reads!=read_count)
                $fatal(1,"early mailbox overwritten under backpressure");
        end
        early_key_ready=1;@(negedge clk);early_key_ready=0;
        expect_status(0);
        if(accepted!=1)$fatal(1,"press duplicated during stall");
        early_key_ready=1;@(negedge clk);early_key_ready=0;
        if(accepted!=2)$fatal(1,"release was not accepted exactly once");
        // 复位撤销未消费状态；重新校准后不可重放旧按键。
        expect_status(0);
        restart();
        model.set_touches(1);expect_status(1);
        // 状态已到达而尾部总线超时：故障取消邮箱，恢复后先等待真实松键。
        wait(model.state==2 && model.ptr==4);hold_scl=1;
        wait(fault);repeat(3)@(negedge clk);
        if(early_key_valid || ready || last_error!=2)$fatal(1,"tail timeout did not cancel mailbox");
        hold_scl=0;
        restart();
        // OVCF高位不允许先发按下，且必须锁定到系统复位。
        model.set_touches(1);model.mem[1]=8'h80;
        wait(fault);repeat(3)@(negedge clk);
        if(early_key_valid || ready || last_error!=5)$fatal(1,"OVCF leaked key status");
        repeat(7000)@(negedge clk);
        if(!fault || ready)$fatal(1,"OVCF recovered without reset");
        $display("MPR121 EARLY MAILBOX PASS early_to_full=%0t ns; coherent status, full 43 bytes, stalls, release, reset, tail timeout, OVCF",full_time-early_time);
        $finish;
    end
    initial begin #8000000;$fatal(1,"early mailbox watchdog state=%0d ready=%b fault=%b",dut.state,ready,fault);end
endmodule
