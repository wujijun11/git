// One-note-at-a-time diagnostic. MIDI 60..75, sine, velocity 100.
// A start edge begins a repeating scale; stop releases the current note.
// NOTE_MS is the held duration after allocation has completed. GAP_MS is
// measured AFTER the allocator reports no remaining voice (release included),
// so every pair of notes has a real digital-silence gap. No CPU is involved.
// Reset must also reset the allocator, audio engine and event queues.
module sequence16_event_source #(
    parameter integer CLK_HZ = 49152000,
    parameter integer NOTE_MS = 400,
    parameter integer GAP_MS = 100
) (
    input wire clk, rst_n,
    input wire start, stop,
    input wire [6:0] active_count,
    input wire allocation_error,
    output wire start_ready,
    output wire busy, holding,
    output reg released_pulse, error,
    output wire event_valid,
    input wire event_ready,
    output wire event_on,
    output wire [5:0] event_source,
    output wire [6:0] event_note, event_velocity,
    output wire [1:0] event_timbre
);
    localparam [63:0] NOTE_RAW = (64'd1 * CLK_HZ * NOTE_MS + 999) / 1000;
    localparam [63:0] GAP_RAW = (64'd1 * CLK_HZ * GAP_MS + 999) / 1000;
    localparam [63:0] NOTE_CYCLES = NOTE_RAW < 1 ? 1 : NOTE_RAW;
    localparam [63:0] GAP_CYCLES = GAP_RAW < 1 ? 1 : GAP_RAW;
    localparam [63:0] MAX_CYCLES = NOTE_CYCLES > GAP_CYCLES ? NOTE_CYCLES : GAP_CYCLES;
    localparam integer TIMER_WIDTH = MAX_CYCLES < 2 ? 1 : $clog2(MAX_CYCLES);
    localparam IDLE=3'd0, SEND_ON=3'd1, WAIT_ON=3'd2, HOLD=3'd3,
               SEND_OFF=3'd4, DRAIN=3'd5, GAP=3'd6;
    reg [2:0] state;
    reg start_previous, stop_pending;
    reg [3:0] note_index;
    reg [TIMER_WIDTH-1:0] timer;
    wire start_edge = start && !start_previous;
    wire abort_now = stop || stop_pending || allocation_error;
    assign busy = rst_n && state != IDLE;
    assign holding = rst_n && state == HOLD;
    assign start_ready = rst_n && state == IDLE && active_count == 0 &&
                         event_ready && !stop && !allocation_error;
    assign event_valid = rst_n && (state == SEND_ON || state == SEND_OFF);
    assign event_on = state == SEND_ON;
    assign event_source = 6'd63;
    assign event_note = 7'd60 + {3'd0, note_index};
    assign event_velocity = 7'd100;
    assign event_timbre = 2'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; start_previous <= 0; stop_pending <= 0;
            note_index <= 0; timer <= 0; released_pulse <= 0; error <= 0;
        end else begin
            start_previous <= start;
            released_pulse <= 0;
            if (state != IDLE && (stop || allocation_error)) stop_pending <= 1;
            if (allocation_error && state != IDLE) error <= 1;
            case (state)
                IDLE: begin
                    stop_pending <= 0;
                    // Busy-time start edges are discarded. A held start never
                    // causes an automatic restart after stop or fault.
                    if (start_edge && !stop) begin
                        if (start_ready) begin
                            state <= SEND_ON; note_index <= 0; timer <= 0; error <= 0;
                        end else error <= 1;
                    end
                end
                SEND_ON: if (event_ready) begin
                    // Once valid has been presented, its payload cannot change
                    // under backpressure. Accept once then release if aborted.
                    timer <= 0;
                    if (abort_now) state <= SEND_OFF;
                    else state <= WAIT_ON;
                end
                WAIT_ON: begin
                    if (abort_now) state <= SEND_OFF;
                    else if (event_ready) begin
                        // Engine ready acknowledges the allocation operation.
                        if (active_count == 1) begin state <= HOLD; timer <= 0; end
                        else begin error <= 1; stop_pending <= 1; state <= SEND_OFF; end
                    end
                end
                HOLD: begin
                    if (abort_now || active_count != 1) begin
                        if (active_count != 1) begin error <= 1; stop_pending <= 1; end
                        state <= SEND_OFF;
                    end else if (timer == NOTE_CYCLES - 1) begin
                        state <= SEND_OFF; timer <= 0;
                    end else timer <= timer + 1'b1;
                end
                SEND_OFF: if (event_ready) state <= DRAIN;
                DRAIN: if (event_ready && active_count == 0) begin
                    timer <= 0;
                    if (abort_now) begin state <= IDLE; released_pulse <= 1; end
                    else state <= GAP;
                end
                GAP: begin
                    if (abort_now) begin state <= IDLE; released_pulse <= 1; end
                    else if (active_count != 0) begin
                        error <= 1; stop_pending <= 1; state <= DRAIN;
                    end else if (timer == GAP_CYCLES - 1) begin
                        // A complete 16-note pass wraps to MIDI 60.
                        note_index <= note_index + 1'b1;
                        state <= SEND_ON; timer <= 0;
                    end else timer <= timer + 1'b1;
                end
                default: begin state <= IDLE; error <= 1; end
            endcase
        end
    end
endmodule
