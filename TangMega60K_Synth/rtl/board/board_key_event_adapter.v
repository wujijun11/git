// Convert debounced board key levels in the audio clock domain into gestures.
// Every transition is queued, including a release while its press is stalled.
// One global queue preserves order; simultaneous transitions enqueue KEY0 first.
// Only the head channel asserts valid, and the head stays until its handshake.
// A bounded queue cannot absorb unbounded input during a stalled downstream;
// overflow_sticky reports that condition and clears with the instrument reset.
module board_key_event_adapter #(
    parameter integer QUEUE_DEPTH = 16,
    parameter integer QUEUE_AWIDTH = 4
) (
    input wire clk,
    input wire rst_n,
    input wire [1:0] pressed,

    output wire key_valid,
    input wire key_ready,
    output wire key_on,
    output wire [5:0] key_source,
    output wire [6:0] key_note,
    output wire [6:0] key_velocity,
    output wire [1:0] key_timbre,

    output wire chord_valid,
    input wire chord_ready,
    output wire chord_on,
    output wire [2:0] chord_id,
    output wire [5:0] chord_source,
    output wire [3:0] chord_count,
    output wire [55:0] chord_notes_flat,
    output wire [6:0] chord_velocity,
    output wire [1:0] chord_timbre,

    output reg overflow_pulse,
    output reg overflow_sticky,
    output wire [QUEUE_AWIDTH:0] pending_count
);
    // entry[1] selects the chord channel; entry[0] is press/release.
    reg [1:0] event_mem [0:QUEUE_DEPTH-1];
    reg [QUEUE_AWIDTH-1:0] read_ptr, write_ptr;
    reg [QUEUE_AWIDTH:0] count;
    reg [1:0] sampled_pressed;

    function [QUEUE_AWIDTH-1:0] next_ptr;
        input [QUEUE_AWIDTH-1:0] ptr;
        reg [QUEUE_AWIDTH:0] incremented_ptr;
        begin
            incremented_ptr = {1'b0, ptr} + 1'b1;
            if (ptr == QUEUE_DEPTH-1)
                next_ptr = {QUEUE_AWIDTH{1'b0}};
            else
                next_ptr = incremented_ptr[QUEUE_AWIDTH-1:0];
        end
    endfunction

    wire [1:0] head = count != 0 ? event_mem[read_ptr] : 2'b00;
    wire [1:0] changed = pressed ^ sampled_pressed;
    assign key_valid = rst_n && count != 0 && !head[1];
    assign chord_valid = rst_n && count != 0 && head[1];
    wire pop = (key_valid && key_ready) || (chord_valid && chord_ready);
    wire [QUEUE_AWIDTH:0] count_after_pop = count - pop;
    wire accept_key = changed[0] && count_after_pop < QUEUE_DEPTH;
    wire accept_chord = changed[1] &&
        (count_after_pop + accept_key < QUEUE_DEPTH);
    wire [QUEUE_AWIDTH-1:0] second_write_ptr =
        accept_key ? next_ptr(write_ptr) : write_ptr;

    assign key_on = head[0];
    assign key_source = 6'd1;
    assign key_note = 7'd69;
    assign key_velocity = key_on ? 7'd100 : 7'd0;
    assign key_timbre = 2'd2;
    assign chord_on = head[0];
    assign chord_id = 3'd0;
    assign chord_source = 6'd2;
    assign chord_count = 4'd3;
    assign chord_notes_flat = {35'd0, 7'd67, 7'd64, 7'd60};
    assign chord_velocity = chord_on ? 7'd100 : 7'd0;
    assign chord_timbre = 2'd2;
    assign pending_count = count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_ptr <= 0;
            write_ptr <= 0;
            count <= 0;
            sampled_pressed <= 0;
            overflow_pulse <= 1'b0;
            overflow_sticky <= 1'b0;
        end else begin
            sampled_pressed <= pressed;
            overflow_pulse <= (changed[0] && !accept_key) ||
                              (changed[1] && !accept_chord);
            if ((changed[0] && !accept_key) || (changed[1] && !accept_chord))
                overflow_sticky <= 1'b1;
            if (pop)
                read_ptr <= next_ptr(read_ptr);
            if (accept_key)
                event_mem[write_ptr] <= {1'b0, pressed[0]};
            if (accept_chord)
                event_mem[second_write_ptr] <= {1'b1, pressed[1]};
            write_ptr <= accept_chord ? next_ptr(second_write_ptr) : second_write_ptr;
            count <= count_after_pop + accept_key + accept_chord;
        end
    end
endmodule
