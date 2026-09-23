// External 24-bit Philips I2S output for a 48 kHz DAC board.
// The board controller uses 50 MHz; the synth uses PLL-derived 49.152 MHz.
// The on-board PT8211 is not driven. Keys 0/1/2 start/stop/reset playback.
module board_audio_48k_i2s_top #(
    parameter integer DEBOUNCE_CYCLES = 500000
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
    wire audio_clk;
    wire pll_locked;
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

    // The board-ready flag and debounced keys originate in the 50 MHz domain.
    // PLL loss asserts reset immediately; release takes two audio-clock edges.
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

    always @(posedge audio_clk or negedge rst_n) begin
        if (!rst_n) start_consumed <= 0;
        else if (!pressed_sync[0]) start_consumed <= 0;
        else if (start_request || busy || pressed_sync[1]) start_consumed <= 1;
    end

    board_bringup_top #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_board (
        .sys_clk(sys_clk), .key_n(key_n), .rgb_data(rgb_data),
        .pa_disable(pa_disable), .board_ready(board_ready),
        .keys_pressed(pressed_50), .status_grb(24'h000000)
    );

    live64_system_top u_live64 (
        .clk(audio_clk), .rst_n(rst_n), .start(start_request),
        .stop(pressed_sync[1]), .start_ready(start_ready), .busy(busy),
        .holding(holding), .released_pulse(released), .error(error),
        .active_count(active_count), .i2s_bclk(i2s_bclk),
        .i2s_lrclk(i2s_lrclk), .i2s_data(i2s_data),
        .underrun_count(underruns)
    );
endmodule
