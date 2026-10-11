`timescale 1ns/1ps
module tb_audio_visualizer;
    reg clk=0;always #5 clk=~clk;reg rn=0,sv=0;reg signed [23:0] l=0,r=0;
    wire [511:0] levels;wire valid,xy,xyv;wire [31:0] drops;wire signed [7:0] wave;reg [7:0] wi=0;
    audio_visualizer dut(.clk(clk),.rst_n(rn),.sample_valid(sv),.sample_left(l),.sample_right(r),
        .spectrum_levels(levels),.spectrum_valid(valid),.dropped_samples(drops),
        .wave_read_index(wi),.wave_data(wave),.xy_read_addr(14'd8256),.xy_pixel(xy),.xy_valid(xyv));
    task frame(input integer k,input integer amplitude);
        begin
            for(integer n=0;n<1024;n=n+1)begin
                @(negedge clk);sv=1;l=$rtoi(amplitude*$sin(6.283185307179586*k*n/1024));r=l;
                @(negedge clk);sv=0;repeat(1022)@(negedge clk);
            end
        end
    endtask
    integer peak,value;
    initial begin
        repeat(3)@(negedge clk);rn=1;frame(7,2097152);
        peak=0;value=0;
        for(integer k=0;k<64;k=k+1)if(levels[k*8+:8]>value)begin peak=k+1;value=levels[k*8+:8];end
        if(peak!=7 || value<120 || drops!=0 || !xyv)$fatal(1,"spectrum peak=%0d value=%0d drops=%0d",peak,value,drops);
        frame(19,2097152);peak=0;value=0;
        for(integer k=0;k<64;k=k+1)if(levels[k*8+:8]>value)begin peak=k+1;value=levels[k*8+:8];end
        if(peak!=19)$fatal(1,"frequency change %d",peak);
        frame(0,0);if(levels!==0)$fatal(1,"silence not clear");
        // Advance the circular waveform head past zero, then read every pixel.
        // A wide array-index sum must wrap explicitly rather than address >255.
        for(integer n=0;n<40;n=n+1)begin
            @(negedge clk);sv=1;l=n*65536;r=0;
            @(negedge clk);sv=0;repeat(1022)@(negedge clk);
        end
        for(integer n=0;n<256;n=n+1)begin
            @(negedge clk);wi=n;repeat(2)@(negedge clk);
            if(wave!==((n<216)?8'd0:(n-216)))$fatal(1,"circular waveform index=%d value=%d",n,wave);
        end
        // Force one monitor overload; audio has no ready output to block it.
        sv=1;repeat(5)@(negedge clk);sv=0;repeat(600)@(negedge clk);
        if(drops!=4)$fatal(1,"overload count %d",drops);
        $display("AUDIO VISUALIZER PASS 64 bins, frequency change, silence, circular waveform, overload");$finish;
    end
    initial begin #40000000;$fatal(1,"timeout");end
endmodule
