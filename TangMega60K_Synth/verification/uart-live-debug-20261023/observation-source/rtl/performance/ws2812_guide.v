// Snapshot-based, MSB-first GRB output for a separate 25-pixel guide panel.
// A constant pixel->key permutation supports row, snake and rotated matrices
// without dividers in the serializer. Default order preserves the old strip.
module ws2812_guide #(
    parameter integer CLK_HZ=49152000,
    parameter integer LED_COUNT=25,
    parameter [7:0] BRIGHTNESS=8'd32,
    parameter [7:0] TOUCH_BRIGHTNESS=8'd16,
    parameter [7:0] MAX_BRIGHTNESS=8'd32,
    // Least significant five bits belong to the first LED after DIN.
    parameter [124:0] PIXEL_KEY_MAP={5'd24,5'd23,5'd22,5'd21,5'd20,
        5'd19,5'd18,5'd17,5'd16,5'd15,5'd14,5'd13,5'd12,5'd11,5'd10,
        5'd9,5'd8,5'd7,5'd6,5'd5,5'd4,5'd3,5'd2,5'd1,5'd0},
    parameter integer T0H_NS=300,
    parameter integer T1H_NS=650,
    parameter integer BIT_NS=1250,
    parameter integer RESET_US=300
) (
    input wire clk, input wire rst_n, input wire [24:0] guide_mask,
    input wire [24:0] touch_mask,
    output wire led_data, output wire busy, output reg frame_done
);
    // V5/W needs both low pulse widths >=580ns and latch low >280us.
    // At 49.152MHz: H0=15, H1=32, bit=62 clocks; L0=47, L1=30.
    localparam integer T0H_CYCLES=(64'd1*CLK_HZ*T0H_NS+999999999)/1000000000;
    localparam integer T1H_CYCLES=(64'd1*CLK_HZ*T1H_NS+999999999)/1000000000;
    localparam integer BIT_CYCLES=(64'd1*CLK_HZ*BIT_NS+999999999)/1000000000;
    localparam integer RESET_CYCLES=(64'd1*CLK_HZ*RESET_US+999999)/1000000;
    localparam integer MAX_CYCLES=(RESET_CYCLES>BIT_CYCLES) ? RESET_CYCLES : BIT_CYCLES;
    localparam integer CYCLE_WIDTH=(MAX_CYCLES>1) ? $clog2(MAX_CYCLES) : 1;
    reg sending, have_frame;
    localparam [7:0] GUIDE_LEVEL=(BRIGHTNESS>MAX_BRIGHTNESS) ? MAX_BRIGHTNESS : BRIGHTNESS;
    localparam [7:0] TOUCH_LEVEL=(TOUCH_BRIGHTNESS>MAX_BRIGHTNESS) ? MAX_BRIGHTNESS : TOUCH_BRIGHTNESS;
    wire [24:0] mapped_guide,mapped_touch;
    reg [24:0] frame_mask,frame_touch;
    genvar pixel;
    generate for(pixel=0;pixel<25;pixel=pixel+1)begin: map_pixels
        localparam integer KEY=PIXEL_KEY_MAP[pixel*5+:5];
        if(KEY<25)begin: valid_key
            assign mapped_guide[pixel]=guide_mask[KEY];
            assign mapped_touch[pixel]=touch_mask[KEY];
        end else begin: invalid_key
            assign mapped_guide[pixel]=1'b0;
            assign mapped_touch[pixel]=1'b0;
        end
    end endgenerate
    // synthesis translate_off
    integer map_a,map_b;
    initial begin
        if(LED_COUNT<1 || LED_COUNT>25)$fatal(1,"WS2812 LED_COUNT must be 1..25");
        for(map_a=0;map_a<25;map_a=map_a+1)begin
            if(PIXEL_KEY_MAP[map_a*5+:5]>=25)$fatal(1,"WS2812 map key out of range");
            for(map_b=0;map_b<map_a;map_b=map_b+1)
                if(PIXEL_KEY_MAP[map_a*5+:5]==PIXEL_KEY_MAP[map_b*5+:5])
                    $fatal(1,"WS2812 map must be a permutation of 0..24");
        end
    end
    // synthesis translate_on
    reg [4:0] bit_index, pixel_index;
    reg [CYCLE_WIDTH-1:0] cycle_count;
    wire [CYCLE_WIDTH:0] incremented_cycle={1'b0,cycle_count}+1'b1;
    // Green = score target, blue = physical touch, cyan = both; red stays off.
    // Both masks are captured together, so a touch cannot tear an LED frame.
    wire [23:0] pixel_grb={frame_mask[pixel_index] ? GUIDE_LEVEL : 8'd0,
        8'd0,frame_touch[pixel_index] ? TOUCH_LEVEL : 8'd0};
    wire bit_value=pixel_grb[23-bit_index];
    assign busy=sending;
    assign led_data=rst_n && sending &&
        cycle_count<(bit_value ? T1H_CYCLES : T0H_CYCLES);
    always @(posedge clk) begin
        if (!rst_n) begin
            sending<=0; have_frame<=0; frame_mask<=0; frame_touch<=0; bit_index<=0; pixel_index<=0;
            cycle_count<=0; frame_done<=0;
        end else begin
            frame_done<=0;
            if (!sending) begin
                if (cycle_count==RESET_CYCLES-1) begin
                    frame_mask<=mapped_guide; frame_touch<=mapped_touch;
                    sending<=1; cycle_count<=0; bit_index<=0; pixel_index<=0;
                    frame_done<=have_frame;
                end else cycle_count<=incremented_cycle[CYCLE_WIDTH-1:0];
            end else if (cycle_count==BIT_CYCLES-1) begin
                cycle_count<=0;
                if (bit_index==23) begin
                    bit_index<=0;
                    if (pixel_index==LED_COUNT-1) begin sending<=0; have_frame<=1; end
                    else pixel_index<=pixel_index+5'd1;
                end else bit_index<=bit_index+5'd1;
            end else cycle_count<=incremented_cycle[CYCLE_WIDTH-1:0];
        end
    end
endmodule
