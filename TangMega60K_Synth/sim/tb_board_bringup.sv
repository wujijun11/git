`timescale 1ns/1ps
module tb_board_bringup;
    reg clk=0;
    always #10 clk=~clk;
    reg [2:0] keys=7;
    wire rgb, mute;
    board_bringup_top #(.DEBOUNCE_CYCLES(8), .HALF_SECOND_CYCLES(25000000))
        dut(.sys_clk(clk),.key_n(keys),.rgb_data(rgb),.pa_disable(mute),.board_ready(),.keys_pressed(),.status_grb(24'd0));
    integer highs, cycles, b;
    reg [23:0] received;
    task read_frame;
        begin
            received=0;
            @(posedge rgb);
            for(b=23;b>=0;b=b-1) begin
                highs=0;
                while(rgb) begin @(negedge clk); if(rgb) highs=highs+1; end
                if(highs!=20 && highs!=40) $fatal(1,"Bad WS2812 high cycles %d",highs);
                received[b]=(highs==40);
                if(b!=0) @(posedge rgb);
            end
        end
    endtask
    initial begin
        repeat(65540) @(negedge clk);
        if(!dut.ready || !mute) $fatal(1,"Startup/mute failure");
        keys=6; repeat(3) @(negedge clk); keys=7;
        repeat(15) @(negedge clk);
        if(dut.key_stable!=7) $fatal(1,"Bounce passed filter");
        keys=6; repeat(15) @(negedge clk);
        if(dut.key_stable!=6) $fatal(1,"Stable press not accepted");
        read_frame();
        if(received!==24'h001000) $fatal(1,"Red GRB wrong: %h",received);
        keys=1; repeat(15) @(negedge clk);
        read_frame();
        if(received!==24'h100010) $fatal(1,"Multi-key GRB wrong: %h",received);
        keys=7; repeat(15) @(negedge clk);
        read_frame();
        if(received!==24'h000000) $fatal(1,"Released frame wrong: %h",received);
        $display("BOARD BRINGUP TESTS PASSED"); $finish;
    end
    initial begin #100000000; $fatal(1,"Timeout"); end
endmodule
