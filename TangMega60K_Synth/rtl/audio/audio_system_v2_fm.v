// Optional FM demonstration top. Board pins, PLL, and captain V2 ports remain
// the captain's responsibility. Timbre 3 becomes FM electric piano only here.
module audio_system_v2_fm (
    input wire clk,rst_n,
    input wire event_valid,
    output wire event_ready,
    input wire event_on,
    input wire [5:0] event_source,
    input wire [6:0] event_note,event_velocity,
    input wire [1:0] event_timbre,
    input wire expr_valid,
    output wire expr_ready,
    input wire [11:0] expr_gain,
    input wire signed [12:0] expr_bend_cents,
    input wire [7:0] expr_vibrato_cents,
    output wire i2s_bclk,i2s_lrclk,i2s_data,
    output wire [6:0] active_count,
    output wire full_pulse,done_error_pulse,
    output wire [31:0] underrun_count
);
    audio_system_v2 #(.FX_ENABLE(1),.FM_ENABLE(1)) u_system (
        .clk(clk),.rst_n(rst_n),.event_valid(event_valid),.event_ready(event_ready),
        .event_on(event_on),.event_source(event_source),
        .event_note(event_note),.event_velocity(event_velocity),
        .event_timbre(event_timbre),.expr_valid(expr_valid),
        .expr_ready(expr_ready),.expr_gain(expr_gain),
        .expr_bend_cents(expr_bend_cents),
        .expr_vibrato_cents(expr_vibrato_cents),
        .i2s_bclk(i2s_bclk),.i2s_lrclk(i2s_lrclk),
        .i2s_data(i2s_data),.active_count(active_count),
        .full_pulse(full_pulse),.done_error_pulse(done_error_pulse),
        .underrun_count(underrun_count)
    );
endmodule
