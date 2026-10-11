// Snapshot-based, MSB-first GRB output for a separate 25-pixel light strip.
module ws2812_guide #(
    parameter integer CLK_HZ=49152000,
    parameter integer LED_COUNT=25,
    parameter [7:0] BRIGHTNESS=8'd32,
    parameter integer T0H_NS=300,
    parameter integer T1H_NS=650,
    parameter integer BIT_NS=1250,
    parameter integer RESET_US=300
) (
    input wire clk, input wire rst_n, input wire [24:0] guide_mask,
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
    reg [24:0] frame_mask;
    reg [4:0] bit_index, pixel_index;
    reg [CYCLE_WIDTH-1:0] cycle_count;
    wire [CYCLE_WIDTH:0] incremented_cycle={1'b0,cycle_count}+1'b1;
    // Green is the first GRB byte; separate counters avoid constant dividers.
    wire bit_value=(bit_index<8) && frame_mask[pixel_index] && BRIGHTNESS[7-bit_index];
    assign busy=sending;
    assign led_data=rst_n && sending &&
        cycle_count<(bit_value ? T1H_CYCLES : T0H_CYCLES);
    always @(posedge clk) begin
        if (!rst_n) begin
            sending<=0; have_frame<=0; frame_mask<=0; bit_index<=0; pixel_index<=0;
            cycle_count<=0; frame_done<=0;
        end else begin
            frame_done<=0;
            if (!sending) begin
                if (cycle_count==RESET_CYCLES-1) begin
                    frame_mask<=guide_mask; sending<=1; cycle_count<=0; bit_index<=0; pixel_index<=0;
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
