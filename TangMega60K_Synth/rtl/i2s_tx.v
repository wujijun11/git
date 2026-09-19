// 24-bit signed stereo, Philips I2S, 32 BCLKs per channel.
// f_sample = f_clk / (BCLK_HALF_DIV * 2 * 64).
// Example: 49.152 MHz / (8 * 2 * 64) = 48 kHz.
// BCLK_HALF_DIV must be >= 1. All state uses clk; BCLK is only an output.
module i2s_tx #(
    parameter integer BCLK_HALF_DIV = 8
) (
    input wire clk,
    input wire rst_n,
    input wire sample_valid,
    output wire sample_ready,
    input wire signed [23:0] sample_left,
    input wire signed [23:0] sample_right,
    output reg i2s_bclk,
    output reg i2s_lrclk,
    output reg i2s_data,
    output reg frame_tick,
    output wire [1:0] fifo_level,
    output reg underrun_pulse,
    output reg underrun_sticky,
    output reg [31:0] underrun_count
);
    function integer counter_width;
        input integer value;
        integer n;
        begin
            n = value - 1;
            counter_width = 0;
            while (n > 0) begin
                counter_width = counter_width + 1;
                n = n >> 1;
            end
            if (counter_width < 1) counter_width = 1;
        end
    endfunction

    localparam integer DIV_WIDTH = counter_width(BCLK_HALF_DIV);
    reg [DIV_WIDTH-1:0] divider;
    // 0/32: WS transition and one-bit I2S delay; 1..24/33..56: data.
    reg [5:0] bit_index;
    reg [47:0] sample_fifo [0:1];
    reg read_ptr, write_ptr;
    reg [1:0] level;
    reg [23:0] left_shift, right_shift;

    wire divider_tick = (divider == BCLK_HALF_DIV - 1);
    wire falling_tick = divider_tick && i2s_bclk;
    wire start_frame = falling_tick && (bit_index == 6'd63);
    wire pop_sample = start_frame && (level != 0);
    wire push_sample = sample_valid && sample_ready;
    // An input accepted exactly on an empty frame boundary is used directly.
    wire bypass_sample = start_frame && (level == 0) && push_sample;
    wire store_sample = push_sample && !bypass_sample;

    assign sample_ready = rst_n && ((level < 2) || pop_sample);
    assign fifo_level = level;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            divider <= 0;
            bit_index <= 6'd63;
            i2s_bclk <= 1'b0;
            i2s_lrclk <= 1'b1;
            i2s_data <= 1'b0;
            frame_tick <= 1'b0;
            read_ptr <= 1'b0;
            write_ptr <= 1'b0;
            level <= 0;
            sample_fifo[0] <= 0;
            sample_fifo[1] <= 0;
            left_shift <= 0;
            right_shift <= 0;
            underrun_pulse <= 1'b0;
            underrun_sticky <= 1'b0;
            underrun_count <= 0;
        end else begin
            frame_tick <= 1'b0;
            underrun_pulse <= 1'b0;

            if (store_sample) begin
                sample_fifo[write_ptr] <= {sample_left, sample_right};
                write_ptr <= !write_ptr;
            end
            if (pop_sample) read_ptr <= !read_ptr;
            case ({store_sample, pop_sample})
                2'b10: level <= level + 1'b1;
                2'b01: level <= level - 1'b1;
                default: level <= level;
            endcase

            if (divider_tick) begin
                divider <= 0;
                i2s_bclk <= !i2s_bclk;
                // Change WS/data on falling edges; DAC samples rising edges.
                if (i2s_bclk) begin
                    bit_index <= bit_index + 6'd1;
                    if (bit_index == 6'd63) begin
                        i2s_lrclk <= 1'b0;
                        i2s_data <= 1'b0;
                        frame_tick <= 1'b1;
                        if (pop_sample) begin
                            left_shift <= sample_fifo[read_ptr][47:24];
                            right_shift <= sample_fifo[read_ptr][23:0];
                        end else if (bypass_sample) begin
                            left_shift <= sample_left;
                            right_shift <= sample_right;
                        end else begin
                            // Never repeat stale audio when the engine is late.
                            left_shift <= 0;
                            right_shift <= 0;
                            underrun_pulse <= 1'b1;
                            underrun_sticky <= 1'b1;
                            if (underrun_count != 32'hffffffff)
                                underrun_count <= underrun_count + 1'b1;
                        end
                    end else if (bit_index == 6'd31) begin
                        i2s_lrclk <= 1'b1;
                        i2s_data <= 1'b0;
                    end else if (bit_index < 6'd24) begin
                        i2s_data <= left_shift[23];
                        left_shift <= {left_shift[22:0], 1'b0};
                    end else if ((bit_index >= 6'd32) && (bit_index < 6'd56)) begin
                        i2s_data <= right_shift[23];
                        right_shift <= {right_shift[22:0], 1'b0};
                    end else begin
                        i2s_data <= 1'b0;
                    end
                end
            end else begin
                divider <= divider + 1'b1;
            end
        end
    end
endmodule
