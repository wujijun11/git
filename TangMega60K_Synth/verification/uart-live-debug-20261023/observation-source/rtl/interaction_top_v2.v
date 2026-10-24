// Teammate B V2 interaction boundary.
//
// Responsibilities covered here:
//   * queue V2 note events with 6-bit event_source;
//   * keep chord releases tied to the notes expanded at chord-on time;
//   * expose backpressure/overflow telemetry instead of silently dropping;
//   * submit complete expression snapshots while allowing each parameter to
//     be updated independently on the B side.
//
// This is still an abstract integration boundary, not a physical sensor
// driver. Board-specific scan, ADC synchronisation, filtering and calibration
// must sit upstream and obey the ready/valid hold rule.
module interaction_top_v2 #(
    parameter integer DEPTH = 32,
    parameter integer AWIDTH = 5,
    parameter integer SOURCE_WIDTH = 6,
    parameter integer CHORD_SLOTS = 8,
    parameter integer CHORD_AWIDTH = 3,
    parameter integer MAX_CHORD_NOTES = 8
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // Already-expanded note event path.
    input  wire                    in_valid,
    output wire                    in_ready,
    input  wire                    in_on,
    input  wire [SOURCE_WIDTH-1:0] in_source,
    input  wire [6:0]              in_note,
    input  wire [6:0]              in_velocity,
    input  wire [1:0]              in_timbre,

    // Optional chord gesture path. chord_notes_flat packs note0 in bits 6:0,
    // note1 in bits 13:7, and so on. Release ignores chord_notes_flat and
    // replays the notes captured on the matching chord-on.
    input  wire                    chord_valid,
    output wire                    chord_ready,
    input  wire                    chord_on,
    input  wire [CHORD_AWIDTH-1:0] chord_id,
    input  wire [SOURCE_WIDTH-1:0] chord_source,
    input  wire [3:0]              chord_count,
    input  wire [MAX_CHORD_NOTES*7-1:0] chord_notes_flat,
    input  wire [6:0]              chord_velocity,
    input  wire [1:0]              chord_timbre,

    output wire                    event_valid,
    input  wire                    event_ready,
    output wire                    event_on,
    output wire [SOURCE_WIDTH-1:0] event_source,
    output wire [6:0]              event_note,
    output wire [6:0]              event_velocity,
    output wire [1:0]              event_timbre,

    // Independent expression update inputs. update_mask bit0=gain,
    // bit1=bend, bit2=vibrato. Each accepted update emits one complete
    // snapshot to the V2 captain expression channel.
    input  wire                    expr_update_valid,
    output wire                    expr_update_ready,
    input  wire [2:0]              expr_update_mask,
    input  wire [11:0]             expr_update_gain,
    input  wire signed [12:0]      expr_update_bend_cents,
    input  wire [7:0]              expr_update_vibrato_cents,
    output wire                    expr_valid,
    input  wire                    expr_ready,
    output wire [11:0]             expr_gain,
    output wire signed [12:0]      expr_bend_cents,
    output wire [7:0]              expr_vibrato_cents,

    output wire [AWIDTH:0]         fifo_level,
    output wire                    fifo_full,
    output wire                    event_backpressure,
    output wire                    overflow_pulse,
    output wire                    overflow_sticky,
    output wire [31:0]             overflow_count,
    output wire [31:0]             pushed_count,
    output wire [31:0]             event_count,
    output wire [11:0]             current_expr_gain,
    output wire signed [12:0]      current_expr_bend_cents,
    output wire [7:0]              current_expr_vibrato_cents
);
    localparam SRC_RAW   = 2'd0;
    localparam SRC_CHORD = 2'd1;
    localparam integer SOURCE_COUNT = (1 << SOURCE_WIDTH);

    reg [1:0] arb_src;
    reg fifo_push_valid;
    reg fifo_push_on;
    reg [SOURCE_WIDTH-1:0] fifo_push_source;
    reg [6:0] fifo_push_note;
    reg [6:0] fifo_push_velocity;
    reg [1:0] fifo_push_timbre;
    wire fifo_push_ready;
    wire do_push = fifo_push_valid && fifo_push_ready;
    wire do_pop  = event_valid && event_ready;

    reg chord_busy;
    reg chord_emit_on;
    reg [CHORD_AWIDTH-1:0] chord_emit_id;
    reg [SOURCE_WIDTH-1:0] chord_emit_source;
    reg [3:0] chord_emit_count;
    reg [3:0] chord_emit_index;
    reg [6:0] chord_emit_velocity;
    reg [1:0] chord_emit_timbre;
    reg chord_held [0:CHORD_SLOTS-1];
    reg [SOURCE_WIDTH-1:0] chord_source_mem [0:CHORD_SLOTS-1];
    reg [3:0] chord_count_mem [0:CHORD_SLOTS-1];
    reg [MAX_CHORD_NOTES*7-1:0] chord_notes_mem [0:CHORD_SLOTS-1];
    reg [1:0] chord_timbre_mem [0:CHORD_SLOTS-1];
    reg raw_held [0:SOURCE_COUNT-1];
    reg [6:0] raw_note_mem [0:SOURCE_COUNT-1];
    reg [1:0] raw_timbre_mem [0:SOURCE_COUNT-1];
    integer i, j;

    wire [3:0] max_chord_notes_w = MAX_CHORD_NOTES;
    wire [3:0] safe_chord_count =
        (chord_count > max_chord_notes_w) ? max_chord_notes_w : chord_count;
    wire [6:0] chord_saved_note =
        chord_notes_mem[chord_emit_id][(chord_emit_index*7) +: 7];
    wire chord_done_this = do_push && (arb_src == SRC_CHORD) &&
                           (chord_emit_index + 1'b1 >= chord_emit_count);
    wire raw_is_release = !in_on || (in_velocity == 0);
    wire raw_release_saved = raw_is_release && raw_held[in_source];
    // An already-held physical source may bounce or repeat. A second key-down
    // must not replace the snapshot needed to release the original note.
    wire raw_duplicate_on = in_on && (in_velocity != 0) && raw_held[in_source];

    assign in_ready = rst_n && !chord_busy && (arb_src == SRC_RAW) &&
                      (raw_duplicate_on || fifo_push_ready);
    assign chord_ready = rst_n && !chord_busy && !in_valid;

    always @(*) begin
        arb_src = SRC_RAW;
        fifo_push_valid = 1'b0;
        fifo_push_on = in_on;
        fifo_push_source = in_source;
        fifo_push_note = raw_release_saved ? raw_note_mem[in_source] : in_note;
        fifo_push_velocity = in_velocity;
        fifo_push_timbre = raw_release_saved ? raw_timbre_mem[in_source] : in_timbre;
        if (chord_busy) begin
            arb_src = SRC_CHORD;
            fifo_push_valid = 1'b1;
            fifo_push_on = chord_emit_on;
            fifo_push_source = chord_emit_source;
            fifo_push_note = chord_saved_note;
            fifo_push_velocity = chord_emit_on ? chord_emit_velocity : 7'd0;
            fifo_push_timbre = chord_emit_timbre;
        end else if (in_valid) begin
            arb_src = SRC_RAW;
            fifo_push_valid = !raw_duplicate_on;
        end
    end

    event_fifo_v2 #(
        .DEPTH(DEPTH), .AWIDTH(AWIDTH), .SOURCE_WIDTH(SOURCE_WIDTH)
    ) u_events (
        .clk(clk), .rst_n(rst_n),
        .push_valid(fifo_push_valid), .push_ready(fifo_push_ready),
        .push_on(fifo_push_on), .push_source(fifo_push_source),
        .push_note(fifo_push_note), .push_velocity(fifo_push_velocity),
        .push_timbre(fifo_push_timbre),
        .pop_valid(event_valid), .pop_ready(event_ready),
        .pop_on(event_on), .pop_source(event_source), .pop_note(event_note),
        .pop_velocity(event_velocity), .pop_timbre(event_timbre),
        .level(fifo_level), .full(fifo_full), .empty()
    );

    reg [31:0] pushed_count_r, event_count_r;
    reg [31:0] overflow_count_r;
    reg overflow_sticky_r;
    reg blocked_d;
    wire blocked = fifo_push_valid && !fifo_push_ready;
    wire overflow_pulse_r = blocked && !blocked_d;

    assign event_backpressure = blocked;
    assign overflow_pulse = overflow_pulse_r;
    assign overflow_sticky = overflow_sticky_r;
    assign overflow_count = overflow_count_r;
    assign pushed_count = pushed_count_r;
    assign event_count = event_count_r;

    reg expr_valid_r;
    reg [11:0] expr_gain_r;
    reg signed [12:0] expr_bend_r;
    reg [7:0] expr_vibrato_r;
    reg [11:0] current_gain_r;
    reg signed [12:0] current_bend_r;
    reg [7:0] current_vibrato_r;

    assign expr_update_ready = rst_n && (!expr_valid_r || expr_ready);
    assign expr_valid = expr_valid_r;
    assign expr_gain = expr_gain_r;
    assign expr_bend_cents = expr_bend_r;
    assign expr_vibrato_cents = expr_vibrato_r;
    assign current_expr_gain = current_gain_r;
    assign current_expr_bend_cents = current_bend_r;
    assign current_expr_vibrato_cents = current_vibrato_r;

    wire expr_update_accept = expr_update_valid && expr_update_ready;
    wire [11:0] next_gain = expr_update_mask[0] ? expr_update_gain : current_gain_r;
    wire signed [12:0] next_bend =
        expr_update_mask[1] ? expr_update_bend_cents : current_bend_r;
    wire [7:0] next_vibrato =
        expr_update_mask[2] ? expr_update_vibrato_cents : current_vibrato_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            chord_busy <= 1'b0;
            chord_emit_on <= 1'b0;
            chord_emit_id <= 0;
            chord_emit_source <= 0;
            chord_emit_count <= 0;
            chord_emit_index <= 0;
            chord_emit_velocity <= 0;
            chord_emit_timbre <= 0;
            pushed_count_r <= 0;
            event_count_r <= 0;
            overflow_count_r <= 0;
            overflow_sticky_r <= 1'b0;
            blocked_d <= 1'b0;
            expr_valid_r <= 1'b0;
            expr_gain_r <= 12'd2048;
            expr_bend_r <= 13'sd0;
            expr_vibrato_r <= 8'd0;
            current_gain_r <= 12'd2048;
            current_bend_r <= 13'sd0;
            current_vibrato_r <= 8'd0;
            for (i = 0; i < CHORD_SLOTS; i = i + 1) begin
                chord_held[i] <= 1'b0;
                chord_source_mem[i] <= 0;
                chord_count_mem[i] <= 0;
                chord_notes_mem[i] <= 0;
                chord_timbre_mem[i] <= 0;
            end
            for (j = 0; j < SOURCE_COUNT; j = j + 1) begin
                raw_held[j] <= 1'b0;
                raw_note_mem[j] <= 0;
                raw_timbre_mem[j] <= 0;
            end
        end else begin
            blocked_d <= blocked;
            if (overflow_pulse_r && overflow_count_r != 32'hffffffff)
                overflow_count_r <= overflow_count_r + 1'b1;
            if (overflow_pulse_r)
                overflow_sticky_r <= 1'b1;
            if (do_push && pushed_count_r != 32'hffffffff)
                pushed_count_r <= pushed_count_r + 1'b1;
            if (do_pop && event_count_r != 32'hffffffff)
                event_count_r <= event_count_r + 1'b1;

            if (do_push && (arb_src == SRC_RAW)) begin
                if (in_on && (in_velocity != 0)) begin
                    raw_held[in_source] <= 1'b1;
                    raw_note_mem[in_source] <= in_note;
                    raw_timbre_mem[in_source] <= in_timbre;
                end else if (raw_held[in_source]) begin
                    raw_held[in_source] <= 1'b0;
                end
            end

            if (!chord_busy && chord_valid && chord_ready) begin
                // Treat a repeated press of a held chord as a no-op. Replacing
                // its snapshot would leave the earlier notes held forever.
                if (!chord_on || !chord_held[chord_id]) begin
                    chord_emit_on <= chord_on;
                    chord_emit_id <= chord_id;
                    chord_emit_source <= chord_on ? chord_source : chord_source_mem[chord_id];
                    chord_emit_count <= chord_on ? safe_chord_count : chord_count_mem[chord_id];
                    chord_emit_index <= 0;
                    chord_emit_velocity <= chord_velocity;
                    chord_emit_timbre <= chord_on ? chord_timbre : chord_timbre_mem[chord_id];
                    chord_busy <= chord_on ? (safe_chord_count != 0) : chord_held[chord_id];
                    if (chord_on) begin
                        chord_held[chord_id] <= (safe_chord_count != 0);
                        chord_source_mem[chord_id] <= chord_source;
                        chord_count_mem[chord_id] <= safe_chord_count;
                        chord_notes_mem[chord_id] <= chord_notes_flat;
                        chord_timbre_mem[chord_id] <= chord_timbre;
                    end
                end
            end else if (chord_done_this) begin
                chord_busy <= 1'b0;
                chord_emit_index <= 0;
                if (!chord_emit_on)
                    chord_held[chord_emit_id] <= 1'b0;
            end else if (do_push && (arb_src == SRC_CHORD)) begin
                chord_emit_index <= chord_emit_index + 1'b1;
            end

            if (expr_valid_r && expr_ready)
                expr_valid_r <= 1'b0;
            if (expr_update_accept) begin
                current_gain_r <= next_gain;
                current_bend_r <= next_bend;
                current_vibrato_r <= next_vibrato;
                expr_gain_r <= next_gain;
                expr_bend_r <= next_bend;
                expr_vibrato_r <= next_vibrato;
                expr_valid_r <= 1'b1;
            end
        end
    end
endmodule
