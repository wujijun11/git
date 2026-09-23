// 48 kHz autonomous digital-only board test. The board controller runs at
// 50 MHz; the synth and I2S use the PLL-derived 49.152 MHz audio clock.
module board_audio_48k_gao_top #(
    parameter integer HOLD_CYCLES=49152000,
    parameter integer RESET_CYCLES=65536,
    parameter integer TIMEOUT_CYCLES=98304000,
    parameter integer REF_CYCLES=5000000
) (
    input wire sys_clk,
    input wire [2:0] key_n,
    output wire rgb_data,
    output wire pa_disable
);
    wire board_ready;
    wire audio_clk;
    wire pll_locked;
    reg ready_meta=0, ready_sync=0;
    wire audio_ready=ready_sync;
    // Compare the audio clock against the independent 50 MHz reference every
    // REF_CYCLES reference edges. REF_CYCLES must be a multiple of 3125.
    localparam integer EXPECTED_AUDIO_CYCLES=(REF_CYCLES/3125)*3072;
    reg [25:0] ref_count=0;
    reg ref_toggle=0;
    reg ref_toggle_meta=0, ref_toggle_sync=0, ref_toggle_prev=0;
    reg ref_started=0;
    reg [25:0] audio_cycle_count=0, measured_cycles=0;
    reg clock_valid=0, clock_good=0;
    audio_clock_48k u_audio_clock (
        .clk_50(sys_clk), .clk_audio(audio_clk), .locked(pll_locked)
    );
    // Asynchronous assertion on PLL loss; synchronous two-stage release in
    // the 49.152 MHz domain after both PLLs and the board controller are ready.
    always @(posedge audio_clk or negedge pll_locked) begin
        if(!pll_locked) begin ready_meta<=0; ready_sync<=0; end
        else begin ready_meta<=board_ready; ready_sync<=ready_meta; end
    end
    always @(posedge sys_clk) begin
        if(ref_count==REF_CYCLES-1) begin
            ref_count<=0;
            ref_toggle<=!ref_toggle;
        end else ref_count<=ref_count+1'b1;
    end
    always @(posedge audio_clk or negedge pll_locked) begin
        if(!pll_locked) begin
            ref_toggle_meta<=0; ref_toggle_sync<=0; ref_toggle_prev<=0;
            ref_started<=0; audio_cycle_count<=0; measured_cycles<=0;
            clock_valid<=0; clock_good<=0;
        end else begin
            ref_toggle_meta<=ref_toggle;
            ref_toggle_sync<=ref_toggle_meta;
            if(ref_toggle_sync!=ref_toggle_prev) begin
                ref_toggle_prev<=ref_toggle_sync;
                if(ref_started) begin
                    measured_cycles<=audio_cycle_count;
                    clock_good<=audio_cycle_count>=EXPECTED_AUDIO_CYCLES-2 &&
                                audio_cycle_count<=EXPECTED_AUDIO_CYCLES+2;
                    clock_valid<=1;
                end else ref_started<=1;
                audio_cycle_count<=1;
            end else audio_cycle_count<=audio_cycle_count+1'b1;
        end
    end
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
        .clk(audio_clk),.rst_n(rst_n),.start(start_request),.stop(stop_request),
        .start_ready(start_ready),.busy(busy),.holding(holding),
        .released_pulse(released),.error(error),.active_count(active_count),
        .i2s_bclk(bclk),.i2s_lrclk(lrclk),.i2s_data(serial_data),
        .underrun_count(underruns)
    );
    always @(posedge audio_clk or negedge pll_locked) begin
        if(!pll_locked || !audio_ready) begin
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
               (clock_valid && !clock_good) ||
               ((phase==START || phase==WAIT_HOLD || phase==DRAIN) && timer>=TIMEOUT_CYCLES-1)) begin
                fault<=1; phase<=FAILED;
            end
        end
    end
endmodule
