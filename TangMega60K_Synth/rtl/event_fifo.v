// Teammate B milestone 03: performance-event queue. Verilog-2001.
// One 17-bit event per entry, laid out as {on, note[6:0], velocity[6:0],
// timbre[1:0]}, matching the captain's event_* interface field for field.
//
// The captain's allocator accepts only one event every ~66 clk cycles
// (64 SCAN + DECIDE + SEND) and its event_ready is also preempted by
// done_valid, so a chord burst must be queued rather than pulsed. This FIFO
// makes event loss structurally impossible: push_ready deasserts when full,
// so a producer that honours the handshake can never be refused silently.
//
// Parameters: AWIDTH must equal log2(DEPTH) and DEPTH must be a power of
// two and at least 2. A non-power-of-two DEPTH would let the pointers wrap
// past the end of mem[] and desynchronise count from wptr/rptr with no
// visible error, so the testbench checks the relation explicitly. DEPTH=1
// cannot be expressed at all, because reg [-1:0] is not legal Verilog-2001.
//
// Handshake properties, all in the clk domain with rst_n active low:
//
//   push side: a transfer completes only on a rising clk edge where
//              push_valid && push_ready. While push_valid && !push_ready
//              the producer MUST hold valid and every payload field.
//   pop side:  same rule in the other direction. The pop payload carries a
//              meaningful event only while pop_valid is high.
//   constraint on the consumer: pop_ready must NOT be a combinational
//              function of pop_valid or of the pop payload. If it were,
//              pop_ready -> do_pop -> count -> empty -> pop_valid would be
//              a real combinational loop. The captain's allocator satisfies
//              this: its event_ready depends only on its own state and on
//              done_valid, never on event_valid.
//
// Occupancy invariant: count == (wptr - rptr) mod DEPTH, and wptr == rptr
// exactly when the FIFO is empty or full. The pop payload is read
// combinationally from mem[rptr]; that word is stable for as long as a
// transfer is stalled, because rptr cannot advance without pop_ready. A
// write can only share an address with rptr in the empty or the full case,
// and in both of those the opposite side is provably idle: when empty,
// pop_valid is low so no read transfer happens; when full, push_ready is
// low so no write happens.
//
// Latency: an accepted event becomes visible on the pop side on the NEXT
// clk edge, never in the same cycle it is accepted. Do not assert
// same-cycle availability.
module event_fifo #(
    parameter integer DEPTH = 32,
    parameter integer AWIDTH = 5
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              push_valid,
    output wire              push_ready,
    input  wire              push_on,
    input  wire [6:0]        push_note,
    input  wire [6:0]        push_velocity,
    input  wire [1:0]        push_timbre,
    output wire              pop_valid,
    input  wire              pop_ready,
    output wire              pop_on,
    output wire [6:0]        pop_note,
    output wire [6:0]        pop_velocity,
    output wire [1:0]        pop_timbre,
    output wire [AWIDTH:0]   level,
    output wire              full,
    output wire              empty
);
    // The event layout is defined here and in the three assign bundles
    // below, nowhere else. Widening the event later (for example to add
    // key_id for same-note multi-key) is a change to these lines only.
    localparam integer EV_WIDTH = 17;

    reg [EV_WIDTH-1:0] mem [0:DEPTH-1];
    reg [AWIDTH-1:0] wptr, rptr;
    reg [AWIDTH:0] count;
    integer i;

    wire do_push = push_valid && push_ready;
    wire do_pop  = pop_valid && pop_ready;

    // The rst_n term here is load-bearing, not cosmetic: mem is cleared in
    // the reset branch below, and Verilog's last-write-wins on mem[wptr]
    // would let a push issued while rst_n is low survive that clear and
    // reappear as a stale event after reset.
    assign push_ready = rst_n && (count != DEPTH);

    assign full  = rst_n && (count == DEPTH);
    assign empty = !rst_n || (count == 0);
    assign level = count;

    // Combinational read; see the occupancy invariant in the header.
    assign pop_valid    = rst_n && !empty;
    assign pop_on       = mem[rptr][16];
    assign pop_note     = mem[rptr][15:9];
    assign pop_velocity = mem[rptr][8:2];
    assign pop_timbre   = mem[rptr][1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr  <= 0;
            rptr  <= 0;
            count <= 0;
            // Clearing mem keeps every waveform X-free and matches the
            // note_mem clear loop in voice_allocator.v.
            //
            // Measured with GOWIN 1.9.12 on the GW5AT-60B, this array maps to
            // one flip-flop per bit: 544 of this module's 560 registers at
            // DEPTH=32, against 272 at DEPTH=16 and 136 at DEPTH=8. Moving
            // mem into its own clocked-only block so a RAM can be inferred
            // was tried and changed nothing - it still came out at 560
            // registers - so the clear is NOT what costs the area, and
            // "optimising" it away buys nothing. DEPTH is the parameter that
            // actually moves the number.
            for (i = 0; i < DEPTH; i = i + 1)
                mem[i] <= 0;
        end else begin
            if (do_push) begin
                mem[wptr] <= {push_on, push_note, push_velocity, push_timbre};
                wptr <= wptr + 1'b1;
            end
            if (do_pop) rptr <= rptr + 1'b1;
            // 2'b11 (simultaneous push and pop) leaves count unchanged.
            case ({do_push, do_pop})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule
