// Milestone 03 diagnostic integration; NOT a physical board top.
// Supply 49.152 MHz with HALF_DIV=8 to obtain 48 kHz audio.
// No PLL, board pin constraints, physical reset synchronization or MCLK yet.
module tone_demo_top #(
    parameter integer BCLK_HALF_DIV = 8,
    parameter [31:0] LEFT_STEP = 32'd39370534,
    parameter [31:0] RIGHT_STEP = 32'd39370534
) (
    input wire clk,
    input wire rst_n,
    output wire i2s_bclk,
    output wire i2s_lrclk,
    output wire i2s_data,
    output wire [31:0] underrun_count
);
    wire valid, ready;
    wire signed [23:0] left_sample, right_sample;
    test_tone_source #(.LEFT_STEP(LEFT_STEP), .RIGHT_STEP(RIGHT_STEP)) u_source (
        .clk(clk), .rst_n(rst_n), .sample_valid(valid), .sample_ready(ready),
        .sample_left(left_sample), .sample_right(right_sample)
    );
    i2s_tx #(.BCLK_HALF_DIV(BCLK_HALF_DIV)) u_tx (
        .clk(clk), .rst_n(rst_n), .sample_valid(valid), .sample_ready(ready),
        .sample_left(left_sample), .sample_right(right_sample),
        .i2s_bclk(i2s_bclk), .i2s_lrclk(i2s_lrclk), .i2s_data(i2s_data),
        .frame_tick(), .fifo_level(), .underrun_pulse(),
        .underrun_sticky(), .underrun_count(underrun_count)
    );
endmodule
