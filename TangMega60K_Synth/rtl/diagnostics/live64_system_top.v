// Independent diagnostic example, NOT a board-pin top: no PLL/CST/SDC.
// Supply 49.152 MHz and coordinated reset. start/stop are synchronized controls,
// NOT raw push-buttons. The existing V2 allocator and Philips I2S are unchanged.
module live64_system_top (
    input wire clk, rst_n, start, stop,
    output wire start_ready, busy, holding, released_pulse, error,
    output wire [6:0] active_count,
    output wire i2s_bclk, i2s_lrclk, i2s_data,
    output wire [31:0] underrun_count
);
    wire event_valid,event_ready,event_on,full_pulse,done_error_pulse;
    wire [5:0] event_source;
    wire [6:0] event_note,event_velocity;
    wire [1:0] event_timbre;
    live64_event_source u_selftest (
        .clk(clk),.rst_n(rst_n),.start(start),.stop(stop),
        .active_count(active_count),.allocation_error(full_pulse || done_error_pulse),
        .start_ready(start_ready),.busy(busy),.holding(holding),
        .released_pulse(released_pulse),.error(error),
        .event_valid(event_valid),.event_ready(event_ready),.event_on(event_on),
        .event_source(event_source),.event_note(event_note),
        .event_velocity(event_velocity),.event_timbre(event_timbre)
    );
    audio_system_v2 #(.FX_ENABLE(0)) u_audio (
        .clk(clk),.rst_n(rst_n),
        .event_valid(event_valid),.event_ready(event_ready),.event_on(event_on),
        .event_source(event_source),.event_note(event_note),
        .event_velocity(event_velocity),.event_timbre(event_timbre),
        // This isolated top always starts in neutral; no sensor can override it.
        .expr_valid(1'b0),.expr_ready(),.expr_gain(12'd2048),
        .expr_bend_cents(13'sd0),.expr_vibrato_cents(8'd0),
        .i2s_bclk(i2s_bclk),.i2s_lrclk(i2s_lrclk),.i2s_data(i2s_data),
        .active_count(active_count),.full_pulse(full_pulse),
        .done_error_pulse(done_error_pulse),.underrun_count(underrun_count)
    );
endmodule
