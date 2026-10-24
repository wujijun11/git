// V2: match a held note by (source, note). V1 remains in voice_allocator.v.
// Source is internal ownership metadata; cmd/done payloads stay V1-compatible.
// One event is scanned over VOICE_COUNT cycles. All interfaces use clk.
// Voice ownership changes ONLY when the engine accepts a command.
// No voice stealing in this milestone: release tails remain allocated.
module voice_allocator_v2 #(
    parameter VOICE_COUNT = 64,
    parameter ID_WIDTH = 6,
    parameter SOURCE_WIDTH = 6
)(
    input wire clk,
    input wire rst_n,
    input wire event_valid,
    output wire event_ready,
    input wire event_on,
    input wire [SOURCE_WIDTH-1:0] event_source,
    input wire [6:0] event_note,
    input wire [6:0] event_velocity,
    input wire [1:0] event_timbre,
    output wire cmd_valid,
    input wire cmd_ready,
    output reg cmd_on,
    output reg [ID_WIDTH-1:0] cmd_voice,
    output reg [6:0] cmd_note,
    output reg [6:0] cmd_velocity,
    output reg [1:0] cmd_timbre,
    input wire done_valid,
    output wire done_ready,
    input wire [ID_WIDTH-1:0] done_voice,
    output reg [ID_WIDTH:0] active_count,
    output reg [VOICE_COUNT-1:0] active_mask,
    output reg [VOICE_COUNT-1:0] held_mask,
    output reg full_pulse,
    output reg ignored_pulse,
    output reg done_error_pulse
);
    localparam IDLE = 2'd0, SCAN = 2'd1, DECIDE = 2'd2, SEND = 2'd3;
    reg [1:0] state;
    reg [6:0] note_mem [0:VOICE_COUNT-1];
    reg [SOURCE_WIDTH-1:0] source_mem [0:VOICE_COUNT-1];
    reg [SOURCE_WIDTH-1:0] pending_source;
    reg pending_on;
    reg [6:0] pending_note, pending_velocity;
    reg [1:0] pending_timbre;
    reg [ID_WIDTH-1:0] scan_id, free_id, match_id;
    reg found_free, found_match;
    integer i;

    // Engine completion has priority in IDLE. Producers must hold valid
    // and payload until ready. Completion is one event, not a sticky level.
    assign done_ready = rst_n && (state == IDLE);
    assign event_ready = rst_n && (state == IDLE) && !done_valid;
    assign cmd_valid = rst_n && (state == SEND);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            active_count <= 0;
            active_mask <= 0;
            held_mask <= 0;
            full_pulse <= 0;
            ignored_pulse <= 0;
            done_error_pulse <= 0;
            pending_on <= 0;
            pending_source <= 0;
            pending_note <= 0;
            pending_velocity <= 0;
            pending_timbre <= 0;
            scan_id <= 0;
            free_id <= 0;
            match_id <= 0;
            found_free <= 0;
            found_match <= 0;
            cmd_on <= 0;
            cmd_voice <= 0;
            cmd_note <= 0;
            cmd_velocity <= 0;
            cmd_timbre <= 0;
            for (i = 0; i < VOICE_COUNT; i = i + 1) begin
                note_mem[i] <= 0;
                source_mem[i] <= 0;
            end
        end else begin
            full_pulse <= 0;
            ignored_pulse <= 0;
            done_error_pulse <= 0;
            case (state)
                IDLE: begin
                    if (done_valid) begin
                        // A held voice cannot finish. Reject duplicate or
                        // invalid completion reports without corrupting count.
                        if (done_voice < VOICE_COUNT) begin
                            if (active_mask[done_voice] && !held_mask[done_voice]) begin
                                active_mask[done_voice] <= 0;
                                active_count <= active_count - 1'b1;
                            end else done_error_pulse <= 1;
                        end else done_error_pulse <= 1;
                    end else if (event_valid) begin
                        // MIDI-style velocity zero has note-off semantics.
                        pending_on <= event_on && (event_velocity != 0);
                        pending_note <= event_note;
                        pending_source <= event_source;
                        pending_velocity <= event_velocity;
                        pending_timbre <= event_timbre;
                        scan_id <= 0;
                        found_free <= 0;
                        found_match <= 0;
                        state <= SCAN;
                    end
                end
                SCAN: begin
                    if (!active_mask[scan_id] && !found_free) begin
                        free_id <= scan_id;
                        found_free <= 1;
                    end
                    if (held_mask[scan_id] && note_mem[scan_id] == pending_note &&
                        source_mem[scan_id] == pending_source && !found_match) begin
                        match_id <= scan_id;
                        found_match <= 1;
                    end
                    if (scan_id == VOICE_COUNT-1) state <= DECIDE;
                    else scan_id <= scan_id + 1'b1;
                end
                DECIDE: begin
                    if (found_match || (pending_on && found_free)) begin
                        cmd_on <= pending_on;
                        cmd_voice <= found_match ? match_id : free_id;
                        cmd_note <= pending_note;
                        cmd_velocity <= pending_velocity;
                        cmd_timbre <= pending_timbre;
                        state <= SEND;
                    end else begin
                        if (pending_on) full_pulse <= 1;
                        else ignored_pulse <= 1;
                        state <= IDLE;
                    end
                end
                SEND: begin
                    if (cmd_ready) begin
                        if (cmd_on) begin
                            if (!active_mask[cmd_voice]) active_count <= active_count + 1'b1;
                            active_mask[cmd_voice] <= 1;
                            held_mask[cmd_voice] <= 1;
                            note_mem[cmd_voice] <= cmd_note;
                            source_mem[cmd_voice] <= pending_source;
                        end else begin
                            // Keep the slot busy through the RELEASE tail.
                            held_mask[cmd_voice] <= 0;
                        end
                        state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
