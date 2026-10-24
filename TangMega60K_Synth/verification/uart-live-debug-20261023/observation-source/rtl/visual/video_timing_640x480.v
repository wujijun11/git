`timescale 1ns/1ps
// VGA-compatible 640x480, 800x525 total, negative sync polarity.
// With exactly 25MHz pixel clock the refresh rate is 59.5238Hz.
module video_timing_640x480 (
    input wire clk,reset,
    output reg [9:0] pixel_x,pixel_y,
    output wire hsync,vsync,de
);
    assign de=pixel_x<640&&pixel_y<480;
    assign hsync=!(pixel_x>=656&&pixel_x<752);
    assign vsync=!(pixel_y>=490&&pixel_y<492);
    always @(posedge clk or posedge reset)begin
        if(reset)begin pixel_x<=0;pixel_y<=0;end
        else if(pixel_x==799)begin
            pixel_x<=0;pixel_y<=pixel_y==524?0:pixel_y+1'b1;
        end else pixel_x<=pixel_x+1'b1;
    end
endmodule

module video_sync_align #(
    parameter integer LATENCY=2
)(
    input wire clk,reset,hsync_in,vsync_in,de_in,
    output wire hsync_out,vsync_out,de_out
);
    generate if(LATENCY==0)begin:zero_latency
        assign hsync_out=hsync_in;assign vsync_out=vsync_in;assign de_out=de_in;
    end else begin:pipeline
        reg [LATENCY-1:0] hp,vp,dp;
        integer i;
        assign hsync_out=hp[LATENCY-1];assign vsync_out=vp[LATENCY-1];assign de_out=dp[LATENCY-1];
        always @(posedge clk or posedge reset)begin
            if(reset)begin hp<={LATENCY{1'b1}};vp<={LATENCY{1'b1}};dp<=0;end
            else begin
                hp[0]<=hsync_in;vp[0]<=vsync_in;dp[0]<=de_in;
                for(i=1;i<LATENCY;i=i+1)begin hp[i]<=hp[i-1];vp[i]<=vp[i-1];dp[i]<=dp[i-1];end
            end
        end
    end endgenerate
endmodule
