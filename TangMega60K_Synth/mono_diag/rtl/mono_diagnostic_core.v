// Isolated speaker diagnostic: one voice, +36.12 dB versus SHIFT=1.
// This scale is safe only because voice 0 must finish before the next note.
// The production 64-voice engine and its master gain are not changed.
module mono_diagnostic_core #(
    parameter integer SAMPLE_RATE=48000,
    parameter integer SINE_ON_FRAMES=28800,
    parameter integer PIANO_ON_FRAMES=19200,
    parameter integer GAP_FRAMES=9600,
    parameter integer MARKER_FRAMES=48000,
    parameter integer BCLK_HALF_DIV=8,
    parameter ROM_DIR="rtl/audio/rom/"
) (
    input wire clk, rst_n, start, stop,
    output wire i2s_bclk, i2s_lrclk, i2s_data,
    output wire busy, start_ready, active,
    output wire [4:0] sequence_index,
    output wire [31:0] underruns
);
    wire cmd_valid, cmd_ready, cmd_on, done_valid, done_ready;
    wire [6:0] cmd_note;
    wire [1:0] cmd_timbre;
    wire [5:0] done_voice;
    wire sample_valid, sample_ready, frame_tick;
    wire signed [23:0] sample_left, sample_right;
    mono_diag_sequence #(.SINE_ON_FRAMES(SINE_ON_FRAMES),
        .PIANO_ON_FRAMES(PIANO_ON_FRAMES), .GAP_FRAMES(GAP_FRAMES),
        .MARKER_FRAMES(MARKER_FRAMES)) u_sequence (
        .clk(clk), .rst_n(rst_n), .start(start), .stop(stop),
        .frame_tick(frame_tick), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_on(cmd_on), .cmd_note(cmd_note), .cmd_timbre(cmd_timbre),
        .done_valid(done_valid), .done_ready(done_ready),
        .busy(busy), .start_ready(start_ready), .active(active),
        .sequence_index(sequence_index)
    );
    voice_engine #(.VOICE_COUNT(1), .SAMPLE_RATE(SAMPLE_RATE),
        .MASTER_SHIFT(7), .FM_ENABLE(0), .FX_ENABLE(0), .PAN_SPREAD(1),
        .ROM_DIR(ROM_DIR)) u_engine (
        .clk(clk), .rst_n(rst_n), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_on(cmd_on), .cmd_voice(6'd0), .cmd_note(cmd_note),
        .cmd_velocity(7'd100), .cmd_timbre(cmd_timbre),
        .done_valid(done_valid), .done_ready(done_ready), .done_voice(done_voice),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_left(sample_left), .sample_right(sample_right),
        .engine_sample_begin(), .active_gain(12'd2048),
        .active_bend_cents(13'sd0), .active_vibrato_cents(8'd0)
    );
    i2s_tx #(.BCLK_HALF_DIV(BCLK_HALF_DIV)) u_sink (
        .clk(clk), .rst_n(rst_n), .sample_valid(sample_valid),
        .sample_ready(sample_ready), .sample_left(sample_left),
        .sample_right(sample_right), .i2s_bclk(i2s_bclk),
        .i2s_lrclk(i2s_lrclk), .i2s_data(i2s_data), .frame_tick(frame_tick),
        .fifo_level(), .underrun_pulse(), .underrun_sticky(),
        .underrun_count(underruns)
    );
endmodule

// Completion handshake, rather than a guessed release timeout, protects the
// single engine voice. Presented commands remain unchanged under backpressure.
module mono_diag_sequence #(
    parameter integer SINE_ON_FRAMES=28800,
    parameter integer PIANO_ON_FRAMES=19200,
    parameter integer GAP_FRAMES=9600,
    parameter integer MARKER_FRAMES=48000
) (
    input wire clk, rst_n, start, stop, frame_tick,
    output wire cmd_valid,
    input wire cmd_ready,
    output wire cmd_on,
    output reg [6:0] cmd_note,
    output wire [1:0] cmd_timbre,
    input wire done_valid,
    output wire done_ready,
    output wire busy, start_ready,
    output reg active,
    output reg [4:0] sequence_index
);
    localparam IDLE=0, SEND_ON=1, HOLD=2, SEND_OFF=3,
               TAIL=4, GAP=5, MARKER=6;
    reg [2:0] state;
    reg previous_start, stop_pending;
    reg [31:0] frames;
    wire abort_now=stop || stop_pending;
    wire [31:0] on_frames=sequence_index<5 ? SINE_ON_FRAMES : PIANO_ON_FRAMES;
    assign busy=rst_n && state!=IDLE;
    assign start_ready=rst_n && state==IDLE && !active &&
                       !done_valid && cmd_ready && !stop;
    assign cmd_valid=rst_n && (state==SEND_ON || state==SEND_OFF);
    assign cmd_on=state==SEND_ON;
    assign cmd_timbre=sequence_index<5 ? 2'd0 : 2'd2;
    assign done_ready=rst_n && state==TAIL;
    always @(*) begin
        case(sequence_index)
            0: cmd_note=64;
            1: cmd_note=65;
            2: cmd_note=67;
            3: cmd_note=62;
            4: cmd_note=60;
            5,6,11,16,17: cmd_note=64;
            7,10: cmd_note=65;
            8,9: cmd_note=67;
            12,15,18,19: cmd_note=62;
            default: cmd_note=60;
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; previous_start<=0; stop_pending<=0;
            frames<=0; active<=0; sequence_index<=0;
        end else begin
            previous_start<=start;
            if(busy && stop) stop_pending<=1;
            case(state)
                IDLE: begin
                    stop_pending<=0; frames<=0;
                    if(start && !previous_start && start_ready) begin
                        sequence_index<=0; state<=SEND_ON;
                    end
                end
                SEND_ON: if(cmd_ready) begin
                    active<=1; frames<=0;
                    state<=abort_now ? SEND_OFF : HOLD;
                end
                HOLD: begin
                    if(abort_now) begin state<=SEND_OFF; frames<=0; end
                    else if(frame_tick) begin
                        if(frames+1>=on_frames) begin state<=SEND_OFF; frames<=0; end
                        else frames<=frames+1'b1;
                    end
                end
                SEND_OFF: if(cmd_ready) begin state<=TAIL; frames<=0; end
                TAIL: begin
                    if(frame_tick && frames<GAP_FRAMES) frames<=frames+1'b1;
                    if(done_valid && done_ready) begin
                        active<=0;
                        state<=abort_now ? IDLE : GAP;
                    end
                end
                GAP: begin
                    if(abort_now) state<=IDLE;
                    else if(frames>=GAP_FRAMES) begin
                        frames<=0;
                        if(sequence_index==20) state<=IDLE;
                        else begin
                            sequence_index<=sequence_index+1'b1;
                            state<=sequence_index==4 ? MARKER : SEND_ON;
                        end
                    end else if(frame_tick) frames<=frames+1'b1;
                end
                MARKER: begin
                    if(abort_now) state<=IDLE;
                    else if(frame_tick) begin
                        if(frames+1>=MARKER_FRAMES) begin state<=SEND_ON; frames<=0; end
                        else frames<=frames+1'b1;
                    end
                end
                default: begin state<=IDLE; active<=0; end
            endcase
        end
    end
endmodule
