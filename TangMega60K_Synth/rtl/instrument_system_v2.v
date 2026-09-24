// Complete logical instrument integration top, not a board-pin top.
//
// This joins the teammate-B input boundary to the 64-voice audio engine and
// standard 24-bit Philips-I2S output. Board clock/reset generation, input
// synchronisers, key scanning, sensor/ADC drivers and pin constraints remain
// outside this module.
module instrument_system_v2 #(
    parameter integer FX_ENABLE = 0,
    parameter integer FM_ENABLE = 0,
    parameter integer EVENT_DEPTH = 32,
    parameter integer EVENT_AWIDTH = 5,
    parameter integer CHORD_SLOTS = 8,
    parameter integer CHORD_AWIDTH = 3,
    parameter integer MAX_CHORD_NOTES = 8
)(
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire                    key_valid,
    output wire                    key_ready,
    input  wire                    key_on,
    input  wire [5:0]              key_source,
    input  wire [6:0]              key_note,
    input  wire [6:0]              key_velocity,
    input  wire [1:0]              key_timbre,

    input  wire                    chord_valid,
    output wire                    chord_ready,
    input  wire                    chord_on,
    input  wire [CHORD_AWIDTH-1:0] chord_id,
    input  wire [5:0]              chord_source,
    input  wire [3:0]              chord_count,
    input  wire [MAX_CHORD_NOTES*7-1:0] chord_notes_flat,
    input  wire [6:0]              chord_velocity,
    input  wire [1:0]              chord_timbre,

    input  wire                    expr_update_valid,
    output wire                    expr_update_ready,
    input  wire [2:0]              expr_update_mask,
    input  wire [11:0]             expr_update_gain,
    input  wire signed [12:0]      expr_update_bend_cents,
    input  wire [7:0]              expr_update_vibrato_cents,

    output wire                    i2s_bclk,
    output wire                    i2s_lrclk,
    output wire                    i2s_data,
    output wire [6:0]              active_count,
    output wire                    voice_full_pulse,
    output wire                    done_error_pulse,
    output wire [31:0]             i2s_underrun_count,

    output wire [EVENT_AWIDTH:0]   event_fifo_level,
    output wire                    event_fifo_full,
    output wire                    event_backpressure,
    output wire                    event_overflow_pulse,
    output wire                    event_overflow_sticky,
    output wire [31:0]             event_overflow_count,
    output wire [31:0]             events_pushed,
    output wire [31:0]             events_delivered,
    output wire [11:0]             current_expr_gain,
    output wire signed [12:0]      current_expr_bend_cents,
    output wire [7:0]              current_expr_vibrato_cents
);
    wire event_valid;
    wire event_ready;
    wire event_on;
    wire [5:0] event_source;
    wire [6:0] event_note;
    wire [6:0] event_velocity;
    wire [1:0] event_timbre;
    wire expr_valid;
    wire expr_ready;
    wire [11:0] expr_gain;
    wire signed [12:0] expr_bend_cents;
    wire [7:0] expr_vibrato_cents;

    interaction_top_v2 #(
        .DEPTH(EVENT_DEPTH),
        .AWIDTH(EVENT_AWIDTH),
        .SOURCE_WIDTH(6),
        .CHORD_SLOTS(CHORD_SLOTS),
        .CHORD_AWIDTH(CHORD_AWIDTH),
        .MAX_CHORD_NOTES(MAX_CHORD_NOTES)
    ) u_inputs (
        .clk(clk), .rst_n(rst_n),
        .in_valid(key_valid), .in_ready(key_ready),
        .in_on(key_on), .in_source(key_source), .in_note(key_note),
        .in_velocity(key_velocity), .in_timbre(key_timbre),
        .chord_valid(chord_valid), .chord_ready(chord_ready),
        .chord_on(chord_on), .chord_id(chord_id),
        .chord_source(chord_source), .chord_count(chord_count),
        .chord_notes_flat(chord_notes_flat),
        .chord_velocity(chord_velocity), .chord_timbre(chord_timbre),
        .event_valid(event_valid), .event_ready(event_ready),
        .event_on(event_on), .event_source(event_source),
        .event_note(event_note), .event_velocity(event_velocity),
        .event_timbre(event_timbre),
        .expr_update_valid(expr_update_valid),
        .expr_update_ready(expr_update_ready),
        .expr_update_mask(expr_update_mask),
        .expr_update_gain(expr_update_gain),
        .expr_update_bend_cents(expr_update_bend_cents),
        .expr_update_vibrato_cents(expr_update_vibrato_cents),
        .expr_valid(expr_valid), .expr_ready(expr_ready),
        .expr_gain(expr_gain), .expr_bend_cents(expr_bend_cents),
        .expr_vibrato_cents(expr_vibrato_cents),
        .fifo_level(event_fifo_level), .fifo_full(event_fifo_full),
        .event_backpressure(event_backpressure),
        .overflow_pulse(event_overflow_pulse),
        .overflow_sticky(event_overflow_sticky),
        .overflow_count(event_overflow_count),
        .pushed_count(events_pushed), .event_count(events_delivered),
        .current_expr_gain(current_expr_gain),
        .current_expr_bend_cents(current_expr_bend_cents),
        .current_expr_vibrato_cents(current_expr_vibrato_cents)
    );

    audio_system_v2 #(.FX_ENABLE(FX_ENABLE), .FM_ENABLE(FM_ENABLE)) u_audio (
        .clk(clk), .rst_n(rst_n),
        .event_valid(event_valid), .event_ready(event_ready),
        .event_on(event_on), .event_source(event_source),
        .event_note(event_note), .event_velocity(event_velocity),
        .event_timbre(event_timbre),
        .expr_valid(expr_valid), .expr_ready(expr_ready),
        .expr_gain(expr_gain), .expr_bend_cents(expr_bend_cents),
        .expr_vibrato_cents(expr_vibrato_cents),
        .i2s_bclk(i2s_bclk), .i2s_lrclk(i2s_lrclk), .i2s_data(i2s_data),
        .active_count(active_count), .full_pulse(voice_full_pulse),
        .done_error_pulse(done_error_pulse),
        .underrun_count(i2s_underrun_count)
    );
endmodule
