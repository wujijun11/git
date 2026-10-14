// Original DAC connector only. J13 is absent from this top and is undriven.
module board_mono_diagnostic_top #(
    parameter integer DEBOUNCE_CYCLES=500000
) (
    input wire sys_clk,
    input wire [2:0] key_n,
    output wire rgb_data, pa_disable,
    output wire i2s_bclk, i2s_lrclk, i2s_data
);
    wire board_ready, audio_clk, pll_locked;
    wire [2:0] pressed_50;
    reg ready_meta=0, ready_sync=0;
    reg [2:0] pressed_meta=0, pressed_sync=0;
    wire rst_n=ready_sync && !pressed_sync[2];
    reg start_consumed=1;
    wire busy, start_ready, active;
    wire [4:0] sequence_index;
    wire [31:0] underruns;
    wire start_request=pressed_sync[0] && !start_consumed && start_ready;
    // GRB: red for a fault, green for sine, blue for piano, dim idle.
    wire [23:0] status_grb=underruns!=0 ? 24'h001000 :
        busy ? (sequence_index<5 ? 24'h100000 : 24'h000010) : 24'h020000;
    reg [23:0] status_meta=0, status_sync=0;
    always @(posedge sys_clk) begin
        status_meta<=status_grb;
        status_sync<=status_meta;
    end
    audio_clock_48k u_audio_clock (
        .clk_50(sys_clk), .clk_audio(audio_clk), .locked(pll_locked)
    );
    board_bringup_top #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES), .STATUS_MODE(1)) u_board (
        .sys_clk(sys_clk), .key_n(key_n), .rgb_data(rgb_data),
        .pa_disable(pa_disable), .board_ready(board_ready),
        .keys_pressed(pressed_50), .status_grb(status_sync)
    );
    always @(posedge audio_clk or negedge pll_locked) begin
        if(!pll_locked) begin
            ready_meta<=0; ready_sync<=0; pressed_meta<=0; pressed_sync<=0;
        end else begin
            ready_meta<=board_ready; ready_sync<=ready_meta;
            pressed_meta<=pressed_50; pressed_sync<=pressed_meta;
        end
    end
    always @(posedge audio_clk or negedge rst_n) begin
        if(!rst_n) start_consumed<=1;
        else if(!pressed_sync[0]) start_consumed<=0;
        else start_consumed<=1;
    end
    mono_diagnostic_core u_diag (
        .clk(audio_clk), .rst_n(rst_n), .start(start_request),
        .stop(pressed_sync[1]), .i2s_bclk(i2s_bclk),
        .i2s_lrclk(i2s_lrclk), .i2s_data(i2s_data),
        .busy(busy), .start_ready(start_ready), .active(active),
        .sequence_index(sequence_index), .underruns(underruns)
    );
endmodule
