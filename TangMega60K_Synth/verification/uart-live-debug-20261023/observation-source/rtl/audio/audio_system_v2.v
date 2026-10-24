// Integration example, NOT a board-pin top. Event/PCM interfaces unchanged.
// Externally supply the documented audio clock and coordinated reset.
// Default: Philips I2S, 24-bit samples in 32-bit slots, WS low=left.
// At 49.152 MHz: Fs=48 kHz, BCLK=3.072 MHz.
module audio_system_v2 #(parameter FX_ENABLE=0, FM_ENABLE=0) (
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
    wire cmd_valid,cmd_ready,cmd_on,done_valid,done_ready,sample_valid,sample_ready;
    wire [5:0] cmd_voice,done_voice;
    wire [6:0] cmd_note,cmd_velocity;
    wire [1:0] cmd_timbre;
    wire signed [23:0] sample_left,sample_right;
    wire engine_sample_begin,expr_applied;
    wire [11:0] active_gain;
    wire signed [12:0] active_bend_cents;
    wire [7:0] active_vibrato_cents;
    captain_system_top_v2 u_captain (
        .clk(clk),.rst_n(rst_n),.event_valid(event_valid),.event_ready(event_ready),
        .event_on(event_on),.event_source(event_source),.event_note(event_note),
        .event_velocity(event_velocity),.event_timbre(event_timbre),
        .expr_valid(expr_valid),.expr_ready(expr_ready),.expr_gain(expr_gain),
        .expr_bend_cents(expr_bend_cents),.expr_vibrato_cents(expr_vibrato_cents),
        .engine_sample_begin(engine_sample_begin),.active_gain(active_gain),
        .active_bend_cents(active_bend_cents),.active_vibrato_cents(active_vibrato_cents),
        .expr_applied(expr_applied),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_on(cmd_on),.cmd_voice(cmd_voice),
        .cmd_note(cmd_note),.cmd_velocity(cmd_velocity),.cmd_timbre(cmd_timbre),
        .done_valid(done_valid),.done_ready(done_ready),.done_voice(done_voice),
        .sample_valid(sample_valid),.sample_ready(sample_ready),
        .sample_left(sample_left),.sample_right(sample_right),
        .i2s_bclk(i2s_bclk),.i2s_lrclk(i2s_lrclk),.i2s_data(i2s_data),
        .active_count(active_count),.active_mask(),.held_mask(),
        .full_pulse(full_pulse),.ignored_pulse(),.done_error_pulse(done_error_pulse),
        .frame_tick(),.fifo_level(),.underrun_pulse(),.underrun_sticky(),.underrun_count(underrun_count)
    );
    voice_engine #(.FX_ENABLE(FX_ENABLE),.FM_ENABLE(FM_ENABLE)) u_engine (
        .clk(clk),.rst_n(rst_n),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_on(cmd_on),.cmd_voice(cmd_voice),
        .cmd_note(cmd_note),.cmd_velocity(cmd_velocity),.cmd_timbre(cmd_timbre),
        .done_valid(done_valid),.done_ready(done_ready),.done_voice(done_voice),
        .sample_valid(sample_valid),.sample_ready(sample_ready),
        .sample_left(sample_left),.sample_right(sample_right),
        .engine_sample_begin(engine_sample_begin),.active_gain(active_gain),
        .active_bend_cents(active_bend_cents),.active_vibrato_cents(active_vibrato_cents)
    );
endmodule

// Alternative synthesis/example top with the 50 ms stereo delay enabled.
module audio_system_v2_delay (
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
    audio_system_v2 #(.FX_ENABLE(1)) u_system (
        .clk(clk),.rst_n(rst_n),.event_valid(event_valid),.event_ready(event_ready),
        .event_on(event_on),.event_source(event_source),.event_note(event_note),
        .event_velocity(event_velocity),.event_timbre(event_timbre),
        .expr_valid(expr_valid),.expr_ready(expr_ready),.expr_gain(expr_gain),
        .expr_bend_cents(expr_bend_cents),.expr_vibrato_cents(expr_vibrato_cents),
        .i2s_bclk(i2s_bclk),.i2s_lrclk(i2s_lrclk),.i2s_data(i2s_data),
        .active_count(active_count),.full_pulse(full_pulse),.done_error_pulse(done_error_pulse),
        .underrun_count(underrun_count)
    );
endmodule
