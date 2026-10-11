`timescale 1ns/1ps
module tb_video_timing;
    reg clk=0;always #20 clk=~clk;reg reset=1;
    wire [9:0] pixel_x,pixel_y;wire hsync,vsync,de,ha,va,da;
    video_timing_640x480 dut(.*);
    video_sync_align align(.clk(clk),.reset(reset),.hsync_in(hsync),.vsync_in(vsync),.de_in(de),.hsync_out(ha),.vsync_out(va),.de_out(da));
    reg hp=1,vp=1,dp=0,he,ve,dexp;
    always @(posedge clk)begin
        if(reset)begin hp=1;vp=1;dp=0;end
        else begin
            he=hp;ve=vp;dexp=dp;hp=hsync;vp=vsync;dp=de;
            #1;if(ha!==he||va!==ve||da!==dexp)$fatal(1,"renderer sync delay mismatch");
        end
    end
    integer i,active=0,hactive=0,vactive=0;
    initial begin
        repeat(3)@(posedge clk);@(negedge clk);reset=0;
        for(i=0;i<800*525;i=i+1)begin
            if(pixel_x!==i%800||pixel_y!==i/800)$fatal(1,"raster counter at %0d",i);
            active=active+de;hactive=hactive+!hsync;vactive=vactive+!vsync;
            @(posedge clk);#2;
        end
        if(pixel_x!=0||pixel_y!=0||active!=640*480||hactive!=96*525||vactive!=2*800)$fatal(1,"frame totals de=%d h=%d v=%d",active,hactive,vactive);
        reset=1;#1;if(da!==0||ha!==1||va!==1)$fatal(1,"align reset");
        $display("ALL VIDEO TIMING TESTS PASSED (800x525 total,640x480 active,negative sync,2-clock alignment)");$finish;
    end
endmodule
