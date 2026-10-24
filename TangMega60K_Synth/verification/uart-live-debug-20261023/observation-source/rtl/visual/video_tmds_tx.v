`timescale 1ns/1ps
// Hardware output uses GW5AT-60 true LVDS pairs and ODDR primitives.
// clk_serial = 5*clk_pixel; DDR serial rate is 10*pixel clock.
// ODDR ports/timing: Gowin UG304 section 4.3.1 and gw5a/prim_sim.v;
// lane order matches Sipeed TangMega-60K-example cam_dvi/src/top.v {r,g,b}.
module video_tmds_tx (
    input wire clk_pixel,clk_serial,reset,
    input wire [7:0] red,green,blue,
    input wire hsync,vsync,de,
    output wire tmds_clk_p,tmds_clk_n,
    output wire [2:0] tmds_data_p,tmds_data_n
);
    wire [9:0] red_symbol,green_symbol,blue_symbol;
    wire [2:0] serial_data;
    wire serial_clock;
    video_tmds_encoder enc_red(.clk(clk_pixel),.reset(reset),.data(red),.de(de),.c0(1'b0),.c1(1'b0),.symbol(red_symbol));
    video_tmds_encoder enc_green(.clk(clk_pixel),.reset(reset),.data(green),.de(de),.c0(1'b0),.c1(1'b0),.symbol(green_symbol));
    video_tmds_encoder enc_blue(.clk(clk_pixel),.reset(reset),.data(blue),.de(de),.c0(hsync),.c1(vsync),.symbol(blue_symbol));
    video_serializer10 red_lane(.clk_pixel(clk_pixel),.clk_serial(clk_serial),.reset(reset),.symbol(red_symbol),.serial(serial_data[2]));
    video_serializer10 green_lane(.clk_pixel(clk_pixel),.clk_serial(clk_serial),.reset(reset),.symbol(green_symbol),.serial(serial_data[1]));
    video_serializer10 blue_lane(.clk_pixel(clk_pixel),.clk_serial(clk_serial),.reset(reset),.symbol(blue_symbol),.serial(serial_data[0]));
    video_serializer10 clock_lane(.clk_pixel(clk_pixel),.clk_serial(clk_serial),.reset(reset),.symbol(10'b1111100000),.serial(serial_clock));
    TLVDS_OBUF clock_buffer(.I(serial_clock),.O(tmds_clk_p),.OB(tmds_clk_n));
    genvar i;generate for(i=0;i<3;i=i+1)begin:diff_lane
        TLVDS_OBUF data_buffer(.I(serial_data[i]),.O(tmds_data_p[i]),.OB(tmds_data_n[i]));
    end endgenerate
endmodule

module video_serializer10 (
    input wire clk_pixel,clk_serial,reset,
    input wire [9:0] symbol,output wire serial
);
    // Keep reset in fabric registers. ODDR has no runtime async reset pin,
    // avoiding fabric-to-HCLK reset recovery at both DDR clock edges.
    // Both clocks come from the same PLL with a fixed 5:1 relationship. The
    // pixel toggle and symbol bus are timed paths, not asynchronous CDCs.
    (* syn_preserve=1 *) reg [1:0] serial_ready=0;
    always @(posedge clk_serial or posedge reset)begin
        if(reset)serial_ready<=0;
        else serial_ready<={serial_ready[0],1'b1};
    end
    reg pixel_tag=0;
    always @(posedge clk_pixel)begin
        if(reset)pixel_tag<=0;else pixel_tag<=~pixel_tag;
    end
    reg seen_tag=0;
    reg [9:0] shift=0;
    always @(posedge clk_serial)begin
        if(!serial_ready[1])begin seen_tag<=0;shift<=0;end
        else if(pixel_tag!=seen_tag)begin seen_tag<=pixel_tag;shift<=symbol;end
        else shift<={2'b00,shift[9:2]};
    end
    ODDR serializer(.CLK(clk_serial),.D0(shift[0]),.D1(shift[1]),
        .TX(1'b0),.Q0(serial),.Q1());
endmodule
