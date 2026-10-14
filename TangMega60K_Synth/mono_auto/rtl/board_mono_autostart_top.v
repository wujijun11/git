// Isolated one-shot speaker diagnostic. The audio core and original DAC pins
// are unchanged; status and the automatic-start timer use the 50 MHz clock.
module board_mono_autostart_top #(
    parameter integer DEBOUNCE_CYCLES=500000,
    parameter integer AUTO_DELAY_CYCLES=100000000,
    parameter integer HEARTBEAT_HALF_CYCLES=25000000
) (
    input wire sys_clk,
    input wire [2:0] key_n,
    output wire rgb_data, pa_disable,
    output wire i2s_bclk, i2s_lrclk, i2s_data
);
    function integer counter_width;
        input integer value;
        integer n;
        begin
            n=value-1; counter_width=0;
            while(n>0) begin counter_width=counter_width+1; n=n>>1; end
            if(counter_width<1) counter_width=1;
        end
    endfunction
    localparam AUTO_WIDTH=counter_width(AUTO_DELAY_CYCLES);
    localparam HEARTBEAT_WIDTH=counter_width(HEARTBEAT_HALF_CYCLES);

    wire board_ready, audio_clk, pll_locked;
    wire [2:0] pressed_50;
    wire busy, start_ready, active;
    wire [4:0] sequence_index;
    wire [31:0] underruns;
    reg pll_meta=0, pll_sync=0;
    reg ready_meta=0, ready_sync=0;
    reg [2:0] pressed_meta=0, pressed_sync=0;
    reg auto_due_meta=0, auto_due_sync=0;
    reg auto_ack_meta=0, auto_ack_sync=0;
    reg audio_ready_meta=0, audio_ready_sync=0;
    reg busy_meta=0, busy_sync=0;
    reg piano_meta=0, piano_sync=0;
    reg underrun_meta=0, underrun_sync=0;
    wire rst_n=ready_sync && !pressed_sync[2];
    reg start_consumed=1;
    // This acknowledgement only changes 0->1. KEY2 and PLL loss must not
    // clear it: reconfiguration is the only way to re-arm automatic playback.
    reg auto_ack=0;
    reg auto_armed=1, auto_due=0;
    reg [AUTO_WIDTH-1:0] auto_count=0;
    reg [HEARTBEAT_WIDTH-1:0] heartbeat_count=0;
    reg heartbeat=0;
    wire manual_start=rst_n && pressed_sync[0] && !start_consumed && start_ready;
    wire automatic_start=rst_n && auto_due_sync && !auto_ack && start_ready;
    wire start_request=manual_start || automatic_start;

    audio_clock_48k u_audio_clock (
        .clk_50(sys_clk), .clk_audio(audio_clk), .locked(pll_locked)
    );
    always @(posedge audio_clk or negedge pll_locked) begin
        if(!pll_locked) begin
            ready_meta<=0; ready_sync<=0; pressed_meta<=0; pressed_sync<=0;
            auto_due_meta<=0; auto_due_sync<=0;
        end else begin
            ready_meta<=board_ready; ready_sync<=ready_meta;
            pressed_meta<=pressed_50; pressed_sync<=pressed_meta;
            auto_due_meta<=auto_due; auto_due_sync<=auto_due_meta;
        end
    end
    always @(posedge audio_clk or negedge rst_n) begin
        if(!rst_n) start_consumed<=1;
        else if(!pressed_sync[0]) start_consumed<=0;
        else start_consumed<=1;
    end
    always @(posedge audio_clk)
        if(start_request) auto_ack<=1;

    // Each asynchronous observation crosses through its own two flip-flops.
    // No decoded multi-bit sequence or color crosses the clock boundary.
    always @(posedge sys_clk) begin
        pll_meta<=pll_locked; pll_sync<=pll_meta;
        auto_ack_meta<=auto_ack; auto_ack_sync<=auto_ack_meta;
        audio_ready_meta<=rst_n; audio_ready_sync<=audio_ready_meta;
        busy_meta<=busy; busy_sync<=busy_meta;
        piano_meta<=sequence_index>=5; piano_sync<=piano_meta;
        underrun_meta<=underruns!=0; underrun_sync<=underrun_meta;
    end
    always @(posedge sys_clk) begin
        if(pressed_50[1] || pressed_50[2] || auto_ack_sync) begin
            auto_armed<=0; auto_due<=0; auto_count<=0;
        end else if(!auto_armed) begin
            auto_due<=0; auto_count<=0;
        end else if(!board_ready || !pll_sync) begin
            // A lock failure before playback restarts the full waiting time.
            // It cannot re-arm an already accepted or cancelled request.
            auto_due<=0; auto_count<=0;
        end else if(!auto_due) begin
            if(auto_count==AUTO_DELAY_CYCLES-1) auto_due<=1;
            else auto_count<=auto_count+1'b1;
        end
    end
    // This heartbeat continues when the audio clock or PLL is unavailable.
    always @(posedge sys_clk) begin
        if(heartbeat_count==HEARTBEAT_HALF_CYCLES-1) begin
            heartbeat_count<=0; heartbeat<=!heartbeat;
        end else heartbeat_count<=heartbeat_count+1'b1;
    end
    // GRB: no lock=red flash; locked but audio reset=yellow flash;
    // idle=dim white flash; sine=green flash; piano=blue flash;
    // a recorded underrun takes priority and remains solid red.
    wire [23:0] status_grb=underrun_sync ? 24'h001000 :
        !heartbeat ? 24'h000000 :
        !pll_sync ? 24'h001000 :
        !audio_ready_sync ? 24'h101000 :
        busy_sync ? (piano_sync ? 24'h000010 : 24'h100000) : 24'h040404;
    board_bringup_top #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES), .STATUS_MODE(1)) u_board (
        .sys_clk(sys_clk), .key_n(key_n), .rgb_data(rgb_data),
        .pa_disable(pa_disable), .board_ready(board_ready),
        .keys_pressed(pressed_50), .status_grb(status_grb)
    );
    mono_diagnostic_core u_diag (
        .clk(audio_clk), .rst_n(rst_n), .start(start_request),
        .stop(pressed_sync[1]), .i2s_bclk(i2s_bclk),
        .i2s_lrclk(i2s_lrclk), .i2s_data(i2s_data),
        .busy(busy), .start_ready(start_ready), .active(active),
        .sequence_index(sequence_index), .underruns(underruns)
    );
endmodule
