// Sequential 16-note sine test with silence between notes. KEY0 starts, KEY1 stops, KEY2 resets.
// Reuses the proven 48 kHz PLL, DAC pins and original 64-voice audio engine.
module board_sequence16_48k_i2s_top #(
    parameter integer DEBOUNCE_CYCLES = 500000,
    parameter integer SEQ_CLK_HZ = 49152000,
    parameter integer NOTE_MS = 400,
    parameter integer GAP_MS = 100
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
    reg start_consumed = 0;
    wire start_ready, busy, holding, released, error;
    wire [6:0] active_count;
    wire [31:0] underruns;
    wire start_request = pressed_sync[0] && !start_consumed && start_ready;

    audio_clock_48k u_audio_clock (
        .clk_50(sys_clk), .clk_audio(audio_clk), .locked(pll_locked)
    );
    board_bringup_top #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_board (
        .sys_clk(sys_clk), .key_n(key_n), .rgb_data(rgb_data),
        .pa_disable(pa_disable), .board_ready(board_ready),
        .keys_pressed(pressed_50), .status_grb(24'h000000)
    );
    always @(posedge audio_clk or negedge pll_locked) begin
        if (!pll_locked) begin
            ready_meta <= 0; ready_sync <= 0;
            pressed_meta <= 0; pressed_sync <= 0;
        end else begin
            ready_meta <= board_ready; ready_sync <= ready_meta;
            pressed_meta <= pressed_50; pressed_sync <= pressed_meta;
        end
    end
    always @(posedge audio_clk or negedge rst_n) begin
        if (!rst_n) start_consumed <= 0;
        else if (!pressed_sync[0]) start_consumed <= 0;
        else if (start_request || busy || pressed_sync[1]) start_consumed <= 1;
    end

    wire event_valid, event_ready, event_on, full_pulse, done_error_pulse;
    wire [5:0] event_source;
    wire [6:0] event_note, event_velocity;
    wire [1:0] event_timbre;
    sequence16_event_source #(.CLK_HZ(SEQ_CLK_HZ),.NOTE_MS(NOTE_MS),.GAP_MS(GAP_MS)) u_selftest (
        .clk(audio_clk), .rst_n(rst_n), .start(start_request),
        .stop(pressed_sync[1]), .active_count(active_count),
        .allocation_error(full_pulse || done_error_pulse),
        .start_ready(start_ready), .busy(busy), .holding(holding),
        .released_pulse(released), .error(error),
        .event_valid(event_valid), .event_ready(event_ready), .event_on(event_on),
        .event_source(event_source), .event_note(event_note),
        .event_velocity(event_velocity), .event_timbre(event_timbre)
    );
    audio_system_v2 #(.FX_ENABLE(0)) u_audio (
        .clk(audio_clk), .rst_n(rst_n),
        .event_valid(event_valid), .event_ready(event_ready), .event_on(event_on),
        .event_source(event_source), .event_note(event_note),
        .event_velocity(event_velocity), .event_timbre(event_timbre),
        .expr_valid(1'b0), .expr_ready(), .expr_gain(12'd2048),
        .expr_bend_cents(13'sd0), .expr_vibrato_cents(8'd0),
        .i2s_bclk(i2s_bclk), .i2s_lrclk(i2s_lrclk), .i2s_data(i2s_data),
        .active_count(active_count), .full_pulse(full_pulse),
        .done_error_pulse(done_error_pulse), .underrun_count(underruns)
    );
endmodule
