// 64 Goertzel analysis bins k=1..64, N=1024, Fs=48k: 46.875..3000Hz.
// This is frequency analysis, not an amplitude-meter masquerading as an FFT.
// At most 8*64 clocks per sample, independent of polyphony. Input is a monitor
// tap: analysis overload is counted, never backpressures the audio stream.
module audio_visualizer #(
    parameter COEFF_FILE="rtl/visual/goertzel_1024_64.hex"
) (
    input wire clk,rst_n,sample_valid,
    input wire signed [23:0] sample_left,sample_right,
    output reg [511:0] spectrum_levels,output reg spectrum_valid,
    output reg [31:0] dropped_samples,
    input wire [7:0] wave_read_index,output reg signed [7:0] wave_data,
    input wire [13:0] xy_read_addr,output reg xy_pixel,output wire xy_valid
);
    reg signed [15:0] coeff[0:63];
    initial $readmemh(COEFF_FILE,coeff);
    reg signed [31:0] q1[0:63],q2[0:63];
    reg signed [7:0] wave_mem[0:255];reg [7:0] wave_ptr;reg [8:0] wave_filled;
    reg xy0[0:16383],xy1[0:16383];reg capture_bank,display_bank,display_valid;
    reg clearing;reg [13:0] clear_ptr;
    wire [6:0] xy_x=sample_left[23:17]+7'd64;
    wire [6:0] xy_y=sample_right[23:17]+7'd64;
    wire [13:0] point={xy_y,xy_x};
    assign xy_valid=display_valid;
    reg [3:0] state;
    reg [5:0] bin;
    reg [9:0] sample_index;
    reg last_sample;
    reg signed [15:0] x,c;
    reg signed [31:0] a,b,n;
    reg signed [47:0] product;
    reg signed [63:0] sqn,sqa,cross_product;
    reg signed [79:0] weighted_cross;
    reg signed [80:0] energy;
    reg [7:0] shadow[0:63];
    integer i;
    function [31:0] sat32;
        input signed [49:0] z;
        begin
            if(z>50'sd2147483647)sat32=32'h7fffffff;
            else if(z< -50'sd2147483648)sat32=32'h80000000;
            else sat32=z[31:0];
        end
    endfunction
    function [7:0] log_height;
        input signed [80:0] e;
        integer h,j;
        begin
            h=0;
            if(e>0)for(j=0;j<80;j=j+1)if(e[j])h=j;
            log_height=(h<=20)?0:((h>=51)?248:(h-20)*8);
        end
    endfunction
    // Display reads and banked XY writes have no route back into synthesis.
    always @(posedge clk) begin
        wave_data<=(wave_filled==256) ? wave_mem[(wave_read_index+wave_ptr)&8'hff] : 8'd0;
        xy_pixel<=display_valid && (display_bank ? xy1[xy_read_addr] : xy0[xy_read_addr]);
        if(clearing)begin
            if(capture_bank)xy1[clear_ptr]<=0;else xy0[clear_ptr]<=0;
        end else if(sample_valid)begin
            if(capture_bank)xy1[point]<=1;else xy0[point]<=1;
        end
        if(sample_valid)wave_mem[wave_ptr]<=sample_left[23:16];
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            state<=0;bin<=0;sample_index<=0;last_sample<=0;spectrum_levels<=0;spectrum_valid<=0;
            dropped_samples<=0;wave_ptr<=0;wave_filled<=0;capture_bank<=0;display_bank<=1;display_valid<=0;
            clearing<=1;clear_ptr<=0;x<=0;c<=0;a<=0;b<=0;n<=0;product<=0;
            sqn<=0;sqa<=0;cross_product<=0;weighted_cross<=0;energy<=0;
            for(i=0;i<64;i=i+1)begin q1[i]<=0;q2[i]<=0;shadow[i]<=0;end
        end else begin
            spectrum_valid<=0;
            if(sample_valid)begin
                wave_ptr<=wave_ptr+1'b1;
                if(wave_filled<256)wave_filled<=wave_filled+1'b1;
                if(state!=0)dropped_samples<=dropped_samples+1'b1;
            end
            if(clearing)begin
                if(clear_ptr==16383)begin clearing<=0;clear_ptr<=0;end
                else clear_ptr<=clear_ptr+1'b1;
            end
            case(state)
                0: if(sample_valid)begin x<=sample_left>>>8;bin<=0;last_sample<=sample_index==1023;state<=1;end
                1: begin a<=q1[bin];b<=q2[bin];c<=coeff[bin];state<=2;end
                2: begin product<=a*c;state<=3;end
                3: begin n<=sat32($signed(x)+($signed(product)>>>14)-$signed(b));state<=4;end
                4: if(last_sample)begin sqn<=$signed(n)*$signed(n);sqa<=$signed(a)*$signed(a);
                    cross_product<=$signed(n)*$signed(a);q1[bin]<=0;q2[bin]<=0;state<=5;end
                    else begin q1[bin]<=n;q2[bin]<=a;
                        if(bin==63)begin sample_index<=sample_index+1'b1;state<=0;end
                        else begin bin<=bin+1'b1;state<=1;end
                    end
                5: begin weighted_cross<=$signed(cross_product)*$signed(c);state<=6;end
                6: begin energy<=$signed(sqn)+$signed(sqa)-($signed(weighted_cross)>>>14);state<=7;end
                7: begin shadow[bin]<=log_height(energy);
                    if(bin==63)state<=8;else begin bin<=bin+1'b1;state<=1;end
                end
                8: begin
                    for(i=0;i<64;i=i+1)spectrum_levels[i*8+:8]<=shadow[i];
                    spectrum_valid<=1;sample_index<=0;state<=0;
                    display_bank<=capture_bank;display_valid<=1;capture_bank<=!capture_bank;
                    clearing<=1;clear_ptr<=0;
                end
                default:state<=0;
            endcase
        end
    end
endmodule
