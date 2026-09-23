// Board integration of the EXISTING 64-voice engine, with no external DAC.
// 50 MHz / 1024 = 48828.125 Hz: digital diagnostic only, not 48 kHz audio.
// No PT8211 signals driven; external I2S pin assignment intentionally deferred.
module board_audio_diagnostic_top #(
    parameter integer DEBOUNCE_CYCLES = 500000
) (
    input wire sys_clk,
    input wire [2:0] key_n,
    output wire rgb_data,
    output wire pa_disable
);
    wire board_ready;
    wire [2:0] pressed;
    wire rst_n = board_ready && !pressed[2];
    wire start_ready,busy,holding,released,error;
    wire [6:0] active_count;
    wire bclk,lrclk,serial_data;
    wire [31:0] underruns;
    reg serial_seen = 0;
    reg fault = 0;
    reg [24:0] heartbeat_counter = 0;
    reg start_consumed = 0;
    wire start_request = pressed[0] && !start_consumed && start_ready;
    always @(posedge sys_clk) begin
        if (!rst_n) begin
            serial_seen<=0; fault<=0; heartbeat_counter<=0; start_consumed<=0;
        end else begin
            heartbeat_counter<=heartbeat_counter+1'b1;
            if (!pressed[0]) start_consumed<=0;
            else if (start_request || busy || pressed[1]) start_consumed<=1;
            if (!busy) serial_seen<=0;
            else if(serial_data) serial_seen<=1;
            // The first I2S frame precedes the first engine sample. Exactly
            // one startup underrun is expected; subsequent ones are faults.
            if(error || underruns>1) fault<=1;
        end
    end
    // Red=fault; cyan=64 active AND nonzero serial data observed;
    // blue=transition; green pulse=idle; yellow=held but no serial data seen.
    wire [23:0] status = !rst_n ? 24'h000000 : fault ? 24'h001000 :
        holding && active_count==64 ? (serial_seen ? 24'h100010 : 24'h101000) :
        busy ? 24'h000010 : (heartbeat_counter[24] ? 24'h040000 : 24'h000000);
    board_bringup_top #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),.STATUS_MODE(1)) u_board (
        .sys_clk(sys_clk),.key_n(key_n),.rgb_data(rgb_data),.pa_disable(pa_disable),
        .board_ready(board_ready),.keys_pressed(pressed),.status_grb(status)
    );
    // Start held through reset is accepted after initialization. A second run
    // requires release and press again, as defined by live64_event_source.
    live64_system_top u_live64 (
        .clk(sys_clk),.rst_n(rst_n),.start(start_request),.stop(pressed[1]),
        .start_ready(start_ready),.busy(busy),.holding(holding),
        .released_pulse(released),.error(error),.active_count(active_count),
        .i2s_bclk(bclk),.i2s_lrclk(lrclk),.i2s_data(serial_data),
        .underrun_count(underruns)
    );
endmodule
