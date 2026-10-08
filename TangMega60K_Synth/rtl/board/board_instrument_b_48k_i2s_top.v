// Playable on-board key bridge: B's interaction path -> A's piano -> PCM5102A.
// KEY0: A4; KEY1: C-major triad; KEY2: reset. Key release sends note-off.
// No CPU or firmware is involved. External I2S pins match the audible self-test.
module board_instrument_b_48k_i2s_top #(
    // 2 ms of continuous stability at 50 MHz leaves room for audio latency.
    // Physical switch bounce still needs validation on the actual board.
    parameter integer DEBOUNCE_CYCLES = 100000
) (
    input wire sys_clk,
    input wire [2:0] key_n,
    output wire rgb_data,
    output wire pa_disable,
    output wire i2s_bclk,
    output wire i2s_lrclk,
    output wire i2s_data
);
    wire board_ready;
    wire [2:0] pressed_50;
    wire audio_clk, pll_locked;
    reg ready_meta = 0, ready_sync = 0;
    reg [2:0] pressed_meta = 0, pressed_sync = 0;
    wire rst_n = ready_sync && !pressed_sync[2];

    audio_clock_48k u_audio_clock (
        .clk_50(sys_clk), .clk_audio(audio_clk), .locked(pll_locked)
    );
    board_bringup_top #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_board (
        .sys_clk(sys_clk), .key_n(key_n), .rgb_data(rgb_data),
        .pa_disable(pa_disable), .board_ready(board_ready),
        .keys_pressed(pressed_50), .status_grb(24'h000000)
    );
    // Loss of PLL lock immediately asserts reset. Only stable debounced key
    // levels cross to the audio domain; two registers synchronise each level.
    always @(posedge audio_clk or negedge pll_locked) begin
        if (!pll_locked) begin
            ready_meta <= 0;
            ready_sync <= 0;
            pressed_meta <= 0;
            pressed_sync <= 0;
        end else begin
            ready_meta <= board_ready;
            ready_sync <= ready_meta;
            pressed_meta <= pressed_50;
            pressed_sync <= pressed_meta;
        end
    end

    wire key_valid, key_ready, key_on;
    wire [5:0] key_source;
    wire [6:0] key_note, key_velocity;
    wire [1:0] key_timbre;
    wire chord_valid, chord_ready, chord_on;
    wire [2:0] chord_id;
    wire [5:0] chord_source;
    wire [3:0] chord_count;
    wire [55:0] chord_notes_flat;
    wire [6:0] chord_velocity;
    wire [1:0] chord_timbre;
    wire input_overflow_pulse, input_overflow_sticky;
    wire [4:0] input_pending_count;
    board_key_event_adapter u_keys (
        .clk(audio_clk), .rst_n(rst_n), .pressed(pressed_sync[1:0]),
        .key_valid(key_valid), .key_ready(key_ready), .key_on(key_on),
        .key_source(key_source), .key_note(key_note),
        .key_velocity(key_velocity), .key_timbre(key_timbre),
        .chord_valid(chord_valid), .chord_ready(chord_ready),
        .chord_on(chord_on), .chord_id(chord_id),
        .chord_source(chord_source), .chord_count(chord_count),
        .chord_notes_flat(chord_notes_flat),
        .chord_velocity(chord_velocity), .chord_timbre(chord_timbre),
        .overflow_pulse(input_overflow_pulse),
        .overflow_sticky(input_overflow_sticky),
        .pending_count(input_pending_count)
    );

    wire [6:0] active_count;
    wire voice_full_pulse, done_error_pulse;
    wire [31:0] underruns;
    wire [5:0] event_fifo_level;
    wire event_fifo_full, event_backpressure;
    wire event_overflow_pulse, event_overflow_sticky;
    wire [31:0] event_overflow_count, events_pushed, events_delivered;
    wire [11:0] current_expr_gain;
    wire signed [12:0] current_expr_bend_cents;
    wire [7:0] current_expr_vibrato_cents;
    // A queue overflow must not leave a lost note-off sounding indefinitely.
    // Mute/reset the instrument until the user presses KEY2 to clear the queue.
    wire instrument_rst_n = rst_n && !input_overflow_sticky;
    instrument_system_v2 u_instrument (
        .clk(audio_clk), .rst_n(instrument_rst_n),
        .key_valid(key_valid), .key_ready(key_ready), .key_on(key_on),
        .key_source(key_source), .key_note(key_note),
        .key_velocity(key_velocity), .key_timbre(key_timbre),
        .chord_valid(chord_valid), .chord_ready(chord_ready),
        .chord_on(chord_on), .chord_id(chord_id),
        .chord_source(chord_source), .chord_count(chord_count),
        .chord_notes_flat(chord_notes_flat),
        .chord_velocity(chord_velocity), .chord_timbre(chord_timbre),
        .expr_update_valid(1'b0), .expr_update_ready(),
        .expr_update_mask(3'b000), .expr_update_gain(12'd2048),
        .expr_update_bend_cents(13'sd0), .expr_update_vibrato_cents(8'd0),
        .i2s_bclk(i2s_bclk), .i2s_lrclk(i2s_lrclk), .i2s_data(i2s_data),
        .active_count(active_count), .voice_full_pulse(voice_full_pulse),
        .done_error_pulse(done_error_pulse), .i2s_underrun_count(underruns),
        .event_fifo_level(event_fifo_level), .event_fifo_full(event_fifo_full),
        .event_backpressure(event_backpressure),
        .event_overflow_pulse(event_overflow_pulse),
        .event_overflow_sticky(event_overflow_sticky),
        .event_overflow_count(event_overflow_count),
        .events_pushed(events_pushed), .events_delivered(events_delivered),
        .current_expr_gain(current_expr_gain),
        .current_expr_bend_cents(current_expr_bend_cents),
        .current_expr_vibrato_cents(current_expr_vibrato_cents)
    );
endmodule
