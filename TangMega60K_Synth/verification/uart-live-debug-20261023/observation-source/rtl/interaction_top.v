// Teammate B milestone 03 integration boundary; NOT a board-pin top level.
// Thin by design, in the same spirit as captain_control_top.v: one
// parameterless instantiation and the captain is done.
//
//   raw sensor adapter --> in_* --> event_fifo --> event_* --> captain
//
// The event_* port group is field-for-field identical to the group on
// captain_control_top.v, so the captain can wire it straight into u_control.
// Nothing else in the captain's tree changes.
//
// Why the FIFO is not optional: the allocator's event_ready is high only in
// IDLE, so after accepting one event it needs SCAN (64 cycles) + DECIDE +
// SEND before it can accept another, and done_valid preempts even that. A
// producer that pulsed valid for a single cycle would silently drop every
// event after the first in a chord. Here push_ready deasserts when the queue
// is full, so an adapter that honours the handshake cannot lose an event.
//
// Deliberately NOT included:
//   * no input skid buffer. It would absorb protocol violations from the
//     future adapter layer and hide them until they became note loss.
//   * no flush port. Flushing could discard a release event, and a lost
//     release means a stuck note: the allocator has no all-notes-off, so
//     rst_n is the only legitimate way to clear it.
//
// Contract the future adapter layer must meet (also stated in the docs):
//   1. while in_valid is high and in_ready is low, hold in_valid and all four
//      payload fields stable;
//   2. do not push while rst_n is low;
//   3. sample in_ready on a clk edge, not on a negedge;
//   4. it owns any clock-domain crossing from an off-chip sensor. Multi-bit
//      signals must not be synchronised bit by bit.
module interaction_top #(
    parameter integer DEPTH  = 32,
    parameter integer AWIDTH = 5
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire        in_on,
    input  wire [6:0]  in_note,
    input  wire [6:0]  in_velocity,
    input  wire [1:0]  in_timbre,
    output wire        event_valid,
    input  wire        event_ready,
    output wire        event_on,
    output wire [6:0]  event_note,
    output wire [6:0]  event_velocity,
    output wire [1:0]  event_timbre,
    output wire [AWIDTH:0] fifo_level,
    output wire        fifo_full,
    output wire        throttle_level,
    output wire        throttle_pulse,
    output wire [31:0] throttle_count,
    output wire [31:0] pushed_count,
    output wire [31:0] event_count
);
    wire do_push = in_valid && in_ready;
    wire do_pop  = event_valid && event_ready;

    event_fifo #(.DEPTH(DEPTH), .AWIDTH(AWIDTH)) u_events (
        .clk(clk), .rst_n(rst_n),
        .push_valid(in_valid), .push_ready(in_ready),
        .push_on(in_on), .push_note(in_note),
        .push_velocity(in_velocity), .push_timbre(in_timbre),
        .pop_valid(event_valid), .pop_ready(event_ready),
        .pop_on(event_on), .pop_note(event_note),
        .pop_velocity(event_velocity), .pop_timbre(event_timbre),
        .level(fifo_level), .full(fifo_full),
        // Unconnected on purpose: fifo_level == 0 already carries the same
        // information and one fewer port is one fewer thing to wire.
        .empty()
    );

    // Combinational constraint this boundary must not break: event_ready
    // feeds pop_ready, so it must not be a combinational function of
    // event_valid or of the event payload. The allocator's event_ready
    // depends only on its own state and on done_valid, so the rule holds
    // today. If a future consumer ever makes ready depend on valid, the loop
    // pop_ready -> do_pop -> count -> empty -> pop_valid becomes real.
    wire in_stall = in_valid && !in_ready;

    // in_stall is a LEVEL, not a pulse. The handshake requires valid to stay
    // high until ready, so this stays asserted for the whole stall, which is
    // roughly the 66 cycles the allocator spends on the previous event.
    // Feeding that level to a counter would over-count by that factor, so the
    // count moves once per stall EPISODE, on the rising edge only. Same shape
    // as underrun_pulse/underrun_count in i2s_tx.v.
    reg  in_stall_d;
    wire throttle_pulse_r = in_stall && !in_stall_d;

    reg [31:0] throttle_count_r;
    reg [31:0] pushed_count_r;
    reg [31:0] event_count_r;

    assign throttle_level = in_stall;
    assign throttle_pulse = throttle_pulse_r;
    assign throttle_count = throttle_count_r;
    assign pushed_count   = pushed_count_r;
    assign event_count    = event_count_r;

    // Conservation, checkable from outside the chip without a probe:
    // pushed_count == event_count + fifo_level, and fifo_level == 0 with
    // pushed_count == event_count means the queue is genuinely drained.
    // A silently dropped release event (a stuck note) shows up as this
    // identity breaking, which is why both counters exist rather than one.
    // The saturating guard mirrors underrun_count in i2s_tx.v; above 2^32
    // events the identity stops holding, which is far beyond any real session.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_stall_d       <= 1'b0;
            throttle_count_r <= 0;
            pushed_count_r   <= 0;
            event_count_r    <= 0;
        end else begin
            in_stall_d <= in_stall;
            if (throttle_pulse_r && throttle_count_r != 32'hffffffff)
                throttle_count_r <= throttle_count_r + 1'b1;
            if (do_push && pushed_count_r != 32'hffffffff)
                pushed_count_r <= pushed_count_r + 1'b1;
            if (do_pop && event_count_r != 32'hffffffff)
                event_count_r <= event_count_r + 1'b1;
        end
    end
endmodule
