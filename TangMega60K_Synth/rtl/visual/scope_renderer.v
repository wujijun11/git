// 640x480 RGB panel: waveform top left, 64-bin spectrum bottom left,
// stereo XY (Lissajous) on the right. Coordinates and RGB share clk.
// A board video transmitter must provide timing and serialize this RGB.
module scope_renderer (
    input wire clk,rst_n,input wire [9:0] x,y,input wire de,
    input wire signed [7:0] wave_data,input wire xy_pixel,xy_valid,
    input wire [511:0] spectrum_levels,
    output wire [7:0] wave_read_index,output wire [13:0] xy_read_addr,
    output reg [23:0] rgb
);
    assign wave_read_index=x[7:0];
    wire [9:0] xx=x-320,yy=y-200;
    assign xy_read_addr={yy[7:1],xx[7:1]};
    reg [9:0] xq,yq;reg deq;
    reg [7:0] height;
    wire signed [10:0] wave_y=11'sd100-($signed(wave_data)>>>1);
    always @* height=spectrum_levels[xq[7:2]*8+:8];
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin xq<=0;yq<=0;deq<=0;rgb<=0;end
        else begin
            xq<=x;yq<=y;deq<=de;
            rgb<=0;
            if(deq)begin
                rgb<=24'h080c18;
                if((xq<256 && (yq==100 || yq==455)) ||
                   (xq>=320 && xq<576 && (xq==448 || yq==328)))rgb<=24'h263449;
                if(xq<256 && yq<200 && $signed({1'b0,yq})==wave_y)rgb<=24'h20e8b0;
                if(xq<256 && yq>=200 && yq<=455 && (455-yq)<height)rgb<=24'h40a0ff;
                if(xq>=320 && xq<576 && yq>=200 && yq<456 && xy_valid && xy_pixel)rgb<=24'hffb040;
            end
        end
    end
endmodule
