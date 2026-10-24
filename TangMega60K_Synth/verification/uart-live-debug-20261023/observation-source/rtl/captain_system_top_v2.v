// Milestone 02 integration boundary, NOT a physical board top.
// All interfaces share clk. At HALF_DIV=8, clk must be 49.152 MHz for 48 kHz.
// The teammate's synthesizer connects cmd/done and signed stereo sample ports.
module captain_system_top_v2 #(
    parameter integer BCLK_HALF_DIV = 8
) (
    input wire clk,
    input wire rst_n,
    input wire event_valid,
    output wire event_ready,
    input wire event_on,
    input wire [5:0] event_source,
    input wire [6:0] event_note,
    input wire [6:0] event_velocity,
    input wire [1:0] event_timbre,
    // Global expression snapshot. All ports use clk.
    input wire expr_valid,
    output wire expr_ready,
    input wire [11:0] expr_gain,
    input wire signed [12:0] expr_bend_cents,
    input wire [7:0] expr_vibrato_cents,
    input wire engine_sample_begin,
    output wire [11:0] active_gain,
    output wire signed [12:0] active_bend_cents,
    output wire [7:0] active_vibrato_cents,
    output wire expr_applied,
    output wire cmd_valid,
    input wire cmd_ready,
    output wire cmd_on,
    output wire [5:0] cmd_voice,
    output wire [6:0] cmd_note,
    output wire [6:0] cmd_velocity,
    output wire [1:0] cmd_timbre,
    input wire done_valid,
    output wire done_ready,
    input wire [5:0] done_voice,
    output wire [6:0] active_count,
    output wire [63:0] active_mask,
    output wire [63:0] held_mask,
    output wire full_pulse,
    output wire ignored_pulse,
    output wire done_error_pulse,
    input wire sample_valid,
    output wire sample_ready,
    input wire signed [23:0] sample_left,
    input wire signed [23:0] sample_right,
    output wire i2s_bclk,
    output wire i2s_lrclk,
    output wire i2s_data,
    output wire frame_tick,
    output wire [1:0] fifo_level,
    output wire underrun_pulse,
    output wire underrun_sticky,
    output wire [31:0] underrun_count
);
    captain_control_top_v2 u_control (
        .clk(clk), .rst_n(rst_n),
        .event_valid(event_valid), .event_ready(event_ready),
        .event_on(event_on), .event_source(event_source), .event_note(event_note),
        .expr_valid(expr_valid), .expr_ready(expr_ready),
        .expr_gain(expr_gain), .expr_bend_cents(expr_bend_cents),
        .expr_vibrato_cents(expr_vibrato_cents),
        .engine_sample_begin(engine_sample_begin),
        .active_gain(active_gain), .active_bend_cents(active_bend_cents),
        .active_vibrato_cents(active_vibrato_cents), .expr_applied(expr_applied),
        .event_velocity(event_velocity), .event_timbre(event_timbre),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_on(cmd_on), .cmd_voice(cmd_voice), .cmd_note(cmd_note),
        .cmd_velocity(cmd_velocity), .cmd_timbre(cmd_timbre),
        .done_valid(done_valid), .done_ready(done_ready), .done_voice(done_voice),
        .active_count(active_count), .active_mask(active_mask), .held_mask(held_mask),
        .full_pulse(full_pulse), .ignored_pulse(ignored_pulse),
        .done_error_pulse(done_error_pulse)
    );

    i2s_tx #(.BCLK_HALF_DIV(BCLK_HALF_DIV)) u_audio (
        .clk(clk), .rst_n(rst_n),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_left(sample_left), .sample_right(sample_right),
        .i2s_bclk(i2s_bclk), .i2s_lrclk(i2s_lrclk), .i2s_data(i2s_data),
        .frame_tick(frame_tick), .fifo_level(fifo_level),
        .underrun_pulse(underrun_pulse), .underrun_sticky(underrun_sticky),
        .underrun_count(underrun_count)
    );
endmodule
