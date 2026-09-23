`timescale 1ns/1ps
module tb_board_gao;
    reg clk=0;
    always #10 clk=~clk;
    wire rgb,mute;
    board_audio_gao_top #(.HOLD_CYCLES(150000),.RESET_CYCLES(32)) dut
        (.sys_clk(clk),.key_n(3'b111),.rgb_data(rgb),.pa_disable(mute));
    integer starts=0, stops=0, holds=0;
    always @(posedge clk) begin
        if(dut.start_request) starts=starts+1;
        if(dut.stop_request) stops=stops+1;
        if(dut.phase==3) begin
            holds=holds+1;
            if(dut.active_count!=64) $fatal(1,"Missing held voices");
        end
        if(dut.fault) $fatal(1,"Automatic diagnostic fault");
        if(!mute) $fatal(1,"Onboard amplifier enabled");
    end
    initial begin
        wait(dut.completed_runs==2);
        if(starts!=2 || stops!=2 || holds<300000 || dut.active_count!=0)
            $fatal(1,"Two automatic runs did not complete");
        wait(dut.holding);
        if(starts!=3 || dut.underruns!=0) $fatal(1,"Reset/restart failed");
        $display("BOARD GAO AUTORUN PASSED runs=2 restart=3"); $finish;
    end
    initial begin #300000000; $fatal(1,"Timeout"); end
endmodule
