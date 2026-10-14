`timescale 1ns/1ps
// Decode only the external waveform, including the quantized production clock.
module ws2812_waveform_check #(
    parameter integer CLK_HZ=20000000,
    parameter integer ZERO_HIGH=6, ONE_HIGH=13, BIT_CLOCKS=25, LATCH_CLOCKS=6000
) (output reg done=0);
    localparam real PERIOD_NS=1000000000.0/CLK_HZ;
    reg clk=0; always #(PERIOD_NS/2.0) clk=!clk;
    reg rst_n=0;
    reg [24:0] guide_mask=25'h1000001;
    wire [24:0] touch_mask=25'd0;
    wire led_data,busy,frame_done;
    ws2812_guide #(.CLK_HZ(CLK_HZ),.BRIGHTNESS(8'h81),.MAX_BRIGHTNESS(8'd255)) dut(.*);
    // This decoder observes the external signal; no internal serializer state is used.
    integer frames=0, zeros=0, ones=0;
    task check_latch;
        input reg completed_frame;
        integer cycle;
        begin
            for(cycle=0;cycle<LATCH_CLOCKS;cycle=cycle+1)begin
                if(busy || led_data || frame_done)$fatal(1,"%0dHz latch low interval too short/high",CLK_HZ);
                @(posedge clk); #1;
            end
            if(!busy || frame_done!==completed_frame)$fatal(1,"%0dHz frame completion/latch length wrong",CLK_HZ);
        end
    endtask
    task check_frame;
        input [24:0] expected_mask; input reg change_midframe;
        integer bitno,cycle,pixel,local_bit,high_clocks;
        reg [23:0] grb; reg expected_bit;
        begin
            if (!busy) $fatal(1,"expected serializer frame start");
            for (bitno=0;bitno<600;bitno=bitno+1) begin
                pixel=bitno/24; local_bit=23-bitno%24;
                grb=expected_mask[pixel] ? 24'h810000 : 24'd0;
                expected_bit=grb[local_bit];
                high_clocks=expected_bit ? ONE_HIGH : ZERO_HIGH;
                if (expected_bit) ones=ones+1; else zeros=zeros+1;
                for (cycle=0;cycle<BIT_CLOCKS;cycle=cycle+1) begin
                    if (!busy || led_data!==(cycle<high_clocks))
                        $fatal(1,"%0dHz pixel %0d bit %0d cycle %0d pulse/order wrong",CLK_HZ,pixel,local_bit,cycle);
                    if (change_midframe && bitno==100 && cycle==5) guide_mask=25'h2;
                    @(posedge clk); #1;
                end
            end
            if (busy || led_data) $fatal(1,"frame did not enter low latch gap after exactly 600 bits");
            check_latch(1);
            frames=frames+1;
        end
    endtask
    initial begin
        // WS2812B-V5/W limits, independent of the DUT's timing constants.
        if(ZERO_HIGH*PERIOD_NS<220 || ZERO_HIGH*PERIOD_NS>380 ||
           ONE_HIGH*PERIOD_NS<580 || ONE_HIGH*PERIOD_NS>1000 ||
           (BIT_CLOCKS-ZERO_HIGH)*PERIOD_NS<580 || (BIT_CLOCKS-ZERO_HIGH)*PERIOD_NS>1000 ||
           (BIT_CLOCKS-ONE_HIGH)*PERIOD_NS<580 || (BIT_CLOCKS-ONE_HIGH)*PERIOD_NS>1000 ||
           LATCH_CLOCKS*PERIOD_NS<=280000)$fatal(1,"test pulse targets violate V5/W datasheet");
        repeat (4) begin @(posedge clk); #1; if (led_data) $fatal(1,"reset pin must be low"); end
        @(negedge clk); rst_n=1;
        check_latch(0);
        check_frame(25'h1000001,1);
        check_frame(25'h2,0);
        // Synchronous state reset plus immediate low output gate aborts a partial frame.
        repeat (50) @(posedge clk);
        @(negedge clk); rst_n=0; #1;
        if (led_data) $fatal(1,"reset failed immediate output-low gate");
        repeat (4) begin @(posedge clk); #1; if (busy || led_data || frame_done) $fatal(1,"reset failed"); end
        @(negedge clk); guide_mask=25'h1ffffff; rst_n=1;
        check_latch(0);
        check_frame(25'h1ffffff,0);
        if (ones!=56 || zeros!=1744) $fatal(1,"decoder did not verify expected GRB bit counts");
        $display("PASS WS2812 %0dHz: %0d frames, GRB order, 0/1 high AND low widths, snapshot, 300us latch, reset",CLK_HZ,frames);
        done=1;
    end
endmodule
module tb_performance_ws2812;
    wire done20,done49;
    ws2812_waveform_check at20(.done(done20));
    ws2812_waveform_check #(.CLK_HZ(49152000),.ZERO_HIGH(15),.ONE_HIGH(32),.BIT_CLOCKS(62),.LATCH_CLOCKS(14746)) at49(.done(done49));
    initial begin wait(done20 && done49);$display("ALL WS2812 WAVEFORM TESTS PASSED");$finish;end
    initial begin #6000000;$fatal(1,"WS2812 simulation watchdog");end
endmodule
