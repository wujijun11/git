// Autonomous digital-only board test. Existing synthesizer/I2S are unchanged.
// 50 MHz / 1024 = 48828.125 Hz; this is not calibrated 48 kHz audio.
module board_audio_gao_top #(
    parameter integer HOLD_CYCLES=50000000,
    parameter integer RESET_CYCLES=65536,
    parameter integer TIMEOUT_CYCLES=100000000
) (
    input wire sys_clk,
    input wire [2:0] key_n,
    output wire rgb_data,
    output wire pa_disable
);
    wire board_ready;
    wire [2:0] pressed;
    localparam RESET=0, START=1, WAIT_HOLD=2, HOLD=3, STOP=4, DRAIN=5, FAILED=6;
    reg [2:0] phase=RESET;
    reg [31:0] timer=0;
    reg [15:0] completed_runs=0;
    reg fault=0, serial_seen=0;
    // Do not drive an asynchronous reset from a multi-bit FSM decode.
    // Register it so state-transition routing skew cannot reset the engine.
    reg rst_n=0;
    wire start_ready,busy,holding,released,error;
    wire [6:0] active_count;
    wire [31:0] underruns;
    wire bclk,lrclk,serial_data;
    wire start_request=phase==START && start_ready;
    wire stop_request=phase==STOP;
    board_bringup_top #(.STATUS_MODE(1)) u_board (
        .sys_clk(sys_clk),.key_n(key_n),.rgb_data(rgb_data),
        .pa_disable(pa_disable),.board_ready(board_ready),
        .keys_pressed(pressed),.status_grb(24'h000000)
    );
    live64_system_top u_live64 (
        .clk(sys_clk),.rst_n(rst_n),.start(start_request),.stop(stop_request),
        .start_ready(start_ready),.busy(busy),.holding(holding),
        .released_pulse(released),.error(error),.active_count(active_count),
        .i2s_bclk(bclk),.i2s_lrclk(lrclk),.i2s_data(serial_data),
        .underrun_count(underruns)
    );
    always @(posedge sys_clk) begin
        if(!board_ready) begin
            rst_n<=0;
            phase<=RESET; timer<=0; completed_runs<=0; fault<=0; serial_seen<=0;
        end else begin
            timer<=timer+1'b1;
            if(rst_n && serial_data) serial_seen<=1;
            case(phase)
                RESET: begin
                    serial_seen<=0;
                    if(timer==RESET_CYCLES-1) begin rst_n<=1; phase<=START; timer<=0; end
                end
                START: if(start_request) begin phase<=WAIT_HOLD; timer<=0; end
                WAIT_HOLD: if(holding && active_count==64) begin phase<=HOLD; timer<=0; end
                HOLD: if(timer==HOLD_CYCLES-1) begin
                    if(active_count!=64 || !serial_seen) begin fault<=1; phase<=FAILED; end
                    else begin phase<=STOP; timer<=0; end
                end
                STOP: begin phase<=DRAIN; timer<=0; end
                DRAIN: if(released && active_count==0) begin
                    rst_n<=0; completed_runs<=completed_runs+1'b1; phase<=RESET; timer<=0;
                end
                FAILED: timer<=0;
                default: begin phase<=FAILED; fault<=1; end
            endcase
            // Sticky failure survives scheduled audio resets and stops the test.
            if((rst_n && (error || underruns!=0)) ||
               ((phase==START || phase==WAIT_HOLD || phase==DRAIN) && timer>=TIMEOUT_CYCLES-1)) begin
                fault<=1; phase<=FAILED;
            end
        end
    end
endmodule
