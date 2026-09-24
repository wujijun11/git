`timescale 1ns/1ps
// Teammate B milestone 03 testbench.
//
// This file is standalone: it never compiles or instantiates the captain's
// RTL. The allocator's accept timing is MODELLED here (one event every 66
// clk cycles, preempted by done_valid) so that the checks depend only on the
// published handshake contract, not on his implementation.
//
// Independent checking philosophy, copied from tb_i2s_tx.sv: no DUT internal
// state is read for checking. The pop payload is judged against a queue fed
// only by accepted push handshakes, and the occupancy invariant is checked
// through the public level output rather than through the pointers.

// Unit case for one event_fifo instance at a given DEPTH.
module fifo_case #(
    parameter integer DEPTH = 32,
    parameter integer AWIDTH = 5
) (output reg finished = 0);
    localparam integer EV_WIDTH = 17;
    localparam integer SOAK_CYCLES = 20000;
    // The soak below can accept at most one push per cycle, so this bound is
    // unreachable by construction. It is kept so that a modelling mistake
    // becomes a loud failure instead of a silent array overrun.
    localparam integer MAXQ = SOAK_CYCLES + 64;

    reg clk = 0;
    // Test clock only: 50 MHz, not a board-clock claim.
    always #10 clk = ~clk;

    reg rst_n = 0;
    reg push_valid = 0;
    reg push_on = 0;
    reg [6:0] push_note = 0;
    reg [6:0] push_velocity = 0;
    reg [1:0] push_timbre = 0;
    reg pop_ready = 0;
    wire push_ready, pop_valid, full, empty;
    wire pop_on;
    wire [6:0] pop_note, pop_velocity;
    wire [1:0] pop_timbre;
    wire [AWIDTH:0] level;

    event_fifo #(.DEPTH(DEPTH), .AWIDTH(AWIDTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .push_valid(push_valid), .push_ready(push_ready),
        .push_on(push_on), .push_note(push_note),
        .push_velocity(push_velocity), .push_timbre(push_timbre),
        .pop_valid(pop_valid), .pop_ready(pop_ready),
        .pop_on(pop_on), .pop_note(pop_note),
        .pop_velocity(pop_velocity), .pop_timbre(pop_timbre),
        .level(level), .full(full), .empty(empty)
    );

    wire [EV_WIDTH-1:0] pop_payload = {pop_on, pop_note, pop_velocity, pop_timbre};

    reg [EV_WIDTH-1:0] expected [0:MAXQ-1];
    integer pushed = 0, delivered = 0, pushed_seen = 0;
    integer accepted_before = 0, popped_before = 0;
    integer full_exchanges = 0;
    // Totals survive the F10 reset so the pass line carries real evidence
    // instead of the zeros the reset would otherwise leave behind.
    integer total_pushed = 0, total_delivered = 0, peak_level = 0;
    integer k, n;

    // Progress traces make a failure locatable in the log without a waveform,
    // which matters because this file runs two instances side by side.
    task automatic mark(input integer id);
        begin
            $display("  DEPTH=%0d case %0d", DEPTH, id);
        end
    endtask

    // Reference queue fed ONLY by accepted push handshakes.
    always @(posedge clk) if (rst_n) begin
        if (push_valid && push_ready) begin
            if (pushed >= MAXQ) $fatal(1, "DEPTH=%0d scoreboard overflow", DEPTH);
            expected[pushed] = {push_on, push_note, push_velocity, push_timbre};
            pushed = pushed + 1;
        end
    end

    // Compare every transferred event against the reference queue.
    always @(posedge clk) if (rst_n) begin
        if (pop_valid && pop_ready) begin
            if (delivered >= pushed)
                $fatal(1, "DEPTH=%0d popped an event that was never pushed", DEPTH);
            if (pop_payload !== expected[delivered])
                $fatal(1, "DEPTH=%0d event %0d mismatch: expected %h got %h",
                       DEPTH, delivered, expected[delivered], pop_payload);
            delivered = delivered + 1;
        end
    end

    // Passive conformance checker: while a transfer is stalled the sender
    // must hold valid and every payload bit. Case-inequality so X/Z fails.
    reg prev_stall = 0;
    reg [EV_WIDTH-1:0] held_payload = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_stall = 0;
            held_payload = 0;
        end else begin
            if (pop_valid !== 1'b0 && pop_valid !== 1'b1)
                $fatal(1, "DEPTH=%0d pop_valid is X/Z", DEPTH);
            if (prev_stall && (pop_valid !== 1'b1 || pop_payload !== held_payload))
                $fatal(1, "DEPTH=%0d source violated ready/valid stability", DEPTH);
            prev_stall = pop_valid && !pop_ready;
            held_payload = pop_payload;
        end
    end

    // Occupancy invariant expressed through public ports only.
    always @(negedge clk) begin
      #1; // Let stimulus and combinational outputs settle before sampling.
      if (rst_n) begin
        if (level !== (pushed - delivered))
            $fatal(1, "DEPTH=%0d level=%0d but pushed-delivered=%0d",
                   DEPTH, level, pushed - delivered);
        if (full !== (level == DEPTH))
            $fatal(1, "DEPTH=%0d full flag disagrees with level", DEPTH);
        if (empty !== (level == 0))
            $fatal(1, "DEPTH=%0d empty flag disagrees with level", DEPTH);
    end

      end

    task automatic reset_system;
        begin
            @(negedge clk);
            rst_n = 0;
            push_valid = 0;
            pop_ready = 0;
            repeat (4) @(negedge clk);
            rst_n = 1;
        end
    endtask

    // One complete push handshake: assert, hold until accepted, deassert.
    task automatic push_event(input bit on_v, input integer note_v,
                              input integer vel_v, input integer timb_v);
        begin
            @(negedge clk);
            push_valid = 1;
            push_on = on_v;
            push_note = note_v[6:0];
            push_velocity = vel_v[6:0];
            push_timbre = timb_v[1:0];
            do @(posedge clk); while (!push_ready);
            @(negedge clk);
            push_valid = 0;
        end
    endtask

    // One complete pop handshake.
    task automatic pop_one;
        begin
            @(negedge clk);
            pop_ready = 1;
            do @(posedge clk); while (!pop_valid);
            @(negedge clk);
            pop_ready = 0;
        end
    endtask

    // Push one event and require the pop side to reproduce it bit for bit.
    // The comparison is stated against an explicit constant rather than
    // against the scoreboard, so this case pins the 17-bit layout itself.
    task automatic check_payload(input bit on_v, input integer note_v,
                                 input integer vel_v, input integer timb_v);
        reg [EV_WIDTH-1:0] want;
        begin
            want = {on_v, note_v[6:0], vel_v[6:0], timb_v[1:0]};
            push_event(on_v, note_v, vel_v, timb_v);
            if (pop_payload !== want)
                $fatal(1, "DEPTH=%0d payload %h came back as %h", DEPTH, want, pop_payload);
            pop_one();
        end
    endtask

    initial begin
        if (DEPTH !== (1 << AWIDTH))
            $fatal(1, "DEPTH=%0d is not 1<<AWIDTH=%0d", DEPTH, 1 << AWIDTH);
        if (DEPTH < 2) $fatal(1, "DEPTH must be at least 2");

        // Force a reset edge even on simulators that initialize regs before
        // scheduling asynchronous-reset blocks.
        #1 rst_n = 1;
        #1 rst_n = 0; // Assert reset before the first rising clock edge.
        reset_system();

        // F1: reset state.
        mark(1);
        if (pop_valid !== 1'b0 || level !== 0 || full !== 1'b0 || empty !== 1'b1)
            $fatal(1, "DEPTH=%0d reset state is wrong", DEPTH);

        // F2: a single push must not bypass to the pop side in the push cycle.
        mark(2);
        @(negedge clk);
        push_valid = 1; push_on = 1; push_note = 7'd60;
        push_velocity = 7'd100; push_timbre = 2'd2;
        if (pop_valid !== 1'b0)
            $fatal(1, "DEPTH=%0d event bypassed in the same cycle", DEPTH);
        do @(posedge clk); while (!push_ready);
        @(negedge clk);
        push_valid = 0;
        if (pop_valid !== 1'b1 || pop_payload !== {1'b1, 7'd60, 7'd100, 2'd2})
            $fatal(1, "DEPTH=%0d event not visible after the push edge", DEPTH);
        pop_one();
        if (level !== 0 || pop_valid !== 1'b0)
            $fatal(1, "DEPTH=%0d event did not drain", DEPTH);

        // F3: strict order over a burst that fills the queue, repeated so the
        // low-depth instance still sees several rounds. Note and velocity are
        // chosen so they can never be equal (36+n against 127-n), so a swap of
        // the two fields inside the 17-bit word cannot cancel itself out.
        mark(3);
        for (k = 0; k < 3; k = k + 1) begin
            for (n = 0; n < DEPTH; n = n + 1)
                push_event(n[0], 36 + n, 127 - n, n[1:0]);
            for (n = 0; n < DEPTH; n = n + 1) pop_one();
        end
        if (delivered !== pushed)
            $fatal(1, "DEPTH=%0d order case did not deliver everything", DEPTH);

        // F4: the payload must freeze while the pop side is stalled.
        mark(4);
        push_event(1, 69, 90, 3);
        @(negedge clk); pop_ready = 0;
        repeat (200) @(negedge clk);
        if (pop_payload !== {1'b1, 7'd69, 7'd90, 2'd3} || level !== 1)
            $fatal(1, "DEPTH=%0d payload moved during a long stall", DEPTH);
        pop_one();

        // F5: fill to capacity, then prove the full side refuses and holds.
        mark(5);
        for (n = 0; n < DEPTH; n = n + 1) push_event(1, n, 64, 0);
        if (level !== DEPTH || full !== 1'b1 || push_ready !== 1'b0)
            $fatal(1, "DEPTH=%0d fill to capacity failed", DEPTH);
        @(negedge clk);
        push_valid = 1; push_on = 1; push_note = 7'd127;
        push_velocity = 7'd127; push_timbre = 2'd3;
        repeat (5) @(negedge clk);
        if (push_ready !== 1'b0 || level !== DEPTH)
            $fatal(1, "DEPTH=%0d full FIFO accepted a push", DEPTH);
        pop_one();
        do @(posedge clk); while (!push_ready);
        @(negedge clk);
        push_valid = 0;
        for (n = 0; n < DEPTH; n = n + 1) pop_one();
        if (level !== 0 || delivered !== pushed)
            $fatal(1, "DEPTH=%0d drain after full case failed", DEPTH);

        // F6: same-cycle push and pop, repeated. The queue cannot be full for
        // this case: while full the push side is refused (F5), so no push can
        // coincide with a pop. The genuine 2'b11 case therefore sits exactly
        // one slot below full. Hold the level there and drive push_valid and
        // pop_ready together; each edge must complete BOTH transfers and leave
        // the level untouched. One instance proves nothing, so this repeats,
        // mirroring the full_exchanges evidence the captain recorded.
        mark(6);
        for (n = 0; n < DEPTH; n = n + 1) push_event(1, n, 64, 0);
        pop_one();
        if (level !== DEPTH - 1)
            $fatal(1, "DEPTH=%0d setup for the same-cycle case failed", DEPTH);
        accepted_before = pushed;
        popped_before = delivered;
        for (n = 0; n < 40; n = n + 1) begin
            @(negedge clk);
            push_valid = 1; push_on = 1; push_note = 7'(n + 64);
            push_velocity = 7'd99; push_timbre = 2'd1;
            pop_ready = 1;
            // Exactly one cycle wide, so exactly one edge can transfer.
            @(posedge clk);
            @(negedge clk);
            push_valid = 0;
            pop_ready = 0;
            if (pushed !== accepted_before + 1 || delivered !== popped_before + 1)
                $fatal(1, "DEPTH=%0d same-cycle edge did not complete both transfers", DEPTH);
            if (level !== DEPTH - 1)
                $fatal(1, "DEPTH=%0d same-cycle exchange moved the level to %0d",
                       DEPTH, level);
            full_exchanges = full_exchanges + 1;
            accepted_before = pushed;
            popped_before = delivered;
        end
        if (full_exchanges < 40) $fatal(1, "DEPTH=%0d same-cycle coverage missing", DEPTH);
        pop_ready = 1;
        while (level != 0) @(negedge clk);
        pop_ready = 0;
        if (delivered !== pushed)
            $fatal(1, "DEPTH=%0d same-cycle case lost or duplicated events", DEPTH);

        // F7: simultaneous push and pop at level 1, the case that would
        // collide if the occupancy counter were wrong.
        mark(7);
        push_event(1, 10, 50, 0);
        @(negedge clk);
        push_valid = 1; push_on = 1; push_note = 7'd11;
        push_velocity = 7'd51; push_timbre = 2'd0;
        pop_ready = 1;
        do @(posedge clk); while (!push_ready);
        @(negedge clk);
        push_valid = 0;
        pop_ready = 1;
        while (level != 0) @(negedge clk);
        pop_ready = 0;
        if (delivered !== pushed)
            $fatal(1, "DEPTH=%0d level-1 exchange failed", DEPTH);

        // F8: empty boundary - a push landing while pop_ready is already high
        // must still be delivered on the next cycle, not in the same one.
        mark(8);
        @(negedge clk);
        push_valid = 1; push_on = 0; push_note = 7'd0;
        push_velocity = 7'd0; push_timbre = 2'd0;
        pop_ready = 1;
        if (pop_valid !== 1'b0)
            $fatal(1, "DEPTH=%0d empty FIFO showed valid", DEPTH);
        do @(posedge clk); while (!push_ready);
        @(negedge clk);
        push_valid = 0;
        pop_ready = 0;
        pop_ready = 1;
        while (level != 0) @(negedge clk);
        pop_ready = 0;
        if (delivered !== pushed)
            $fatal(1, "DEPTH=%0d empty-boundary case failed", DEPTH);

        // F11: payload boundaries and deliberately asymmetric values, pushed
        // and popped one at a time so the case also fits a depth-2 queue.
        // Every pair below except the all-zero one has note != velocity, so a
        // field swap inside the 17-bit word cannot cancel itself out. The
        // all-zero entry is kept because it is the value a never-written slot
        // would read back as.
        mark(11);
        check_payload(0, 0, 0, 0);
        check_payload(1, 127, 0, 3);    // max note, min velocity
        check_payload(1, 69, 0, 1);     // velocity 0 must pass through verbatim
        check_payload(0, 60, 3, 2);
        check_payload(1, 0, 127, 3);    // min note, max velocity
        check_payload(0, 127, 125, 0);
        if (delivered !== pushed)
            $fatal(1, "DEPTH=%0d asymmetric payload case failed", DEPTH);

        // F9: random soak - random pushes with random holds, random pops.
        mark(9);
        for (k = 0; k < SOAK_CYCLES; k = k + 1) begin
            @(negedge clk);
            if (push_valid && (pushed != pushed_seen)) push_valid = 0;
            pushed_seen = pushed;
            if (!push_valid && (($random % 2) == 0)) begin
                push_valid = 1;
                push_on = $random;
                push_note = $random;
                push_velocity = $random;
                push_timbre = $random;
            end
            pop_ready = (($random % 2) == 0);
            if (level > peak_level) peak_level = level;
        end
        push_valid = 0;
        pop_ready = 1;
        while (level != 0) @(negedge clk);
        pop_ready = 0;
        if (delivered !== pushed)
            $fatal(1, "DEPTH=%0d random soak lost or duplicated events", DEPTH);

        // F10: reset while full and while stalled must not leak a phantom.
        mark(10);
        total_pushed = pushed;
        total_delivered = delivered;
        for (n = 0; n < DEPTH; n = n + 1) push_event(1, n + 1, 70, 1);
        @(negedge clk);
        push_valid = 1; push_on = 1; push_note = 7'd99;
        push_velocity = 7'd77; push_timbre = 2'd2;
        rst_n = 0;
        repeat (3) @(negedge clk);
        if (pop_valid !== 1'b0 || level !== 0 || full !== 1'b0)
            $fatal(1, "DEPTH=%0d reset did not clear the queue", DEPTH);
        push_valid = 0;
        rst_n = 1;
        // The DUT has been cleared, so the reference counters must be cleared
        // with it or the occupancy invariant below would compare a fresh level
        // against pre-reset totals and report a false desync.
        pushed = 0;
        delivered = 0;
        pushed_seen = 0;
        repeat (3) @(negedge clk);
        if (pop_valid !== 1'b0 || level !== 0)
            $fatal(1, "DEPTH=%0d stale event survived reset", DEPTH);

        // A soak that never raised the level would say nothing about depth, so
        // it is asserted rather than left to chance. The full-exchange count
        // is the evidence the captain recorded for the audio FIFO.
        if (full_exchanges == 0) $fatal(1, "DEPTH=%0d full-exchange coverage missing", DEPTH);
        if (peak_level == 0) $fatal(1, "DEPTH=%0d soak never queued anything", DEPTH);
        $display("FIFO CASE PASSED DEPTH=%0d pushed=%0d delivered=%0d full_exchange=%0d peak_level=%0d",
                 DEPTH, total_pushed, total_delivered, full_exchanges, peak_level);
        finished = 1;
    end
endmodule

// Integration case for interaction_top, at the depth the captain will
// instantiate. The allocator's accept timing is MODELLED here from its
// published contract, so this file compiles none of the captain's RTL and a
// failure here cannot be blamed on it, nor caused by a change to it.
module interaction_case #(
    parameter integer DEPTH  = 32,
    parameter integer AWIDTH = 5
) (output reg finished = 0);
    localparam integer EV_WIDTH = 17;
    localparam integer MAXQ = 4096;
    // SCAN is 64 cycles, plus DECIDE and SEND. The exact figure is the
    // captain's; what matters to this test is that it is far larger than one
    // cycle, which is what makes the queue load-bearing.
    localparam integer BUSY_CYCLES = 66;

    reg clk = 0;
    // Test clock only: 50 MHz, not a board-clock claim.
    always #10 clk = ~clk;

    reg rst_n = 0;
    reg in_valid = 0, in_on = 0;
    reg [6:0] in_note = 0, in_velocity = 0;
    reg [1:0] in_timbre = 0;
    wire in_ready;
    wire event_valid, event_on;
    wire [6:0] event_note, event_velocity;
    wire [1:0] event_timbre;
    reg event_ready = 0;
    wire [AWIDTH:0] fifo_level;
    wire fifo_full, throttle_level, throttle_pulse;
    wire [31:0] throttle_count, pushed_count, event_count;

    interaction_top #(.DEPTH(DEPTH), .AWIDTH(AWIDTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_ready(in_ready),
        .in_on(in_on), .in_note(in_note),
        .in_velocity(in_velocity), .in_timbre(in_timbre),
        .event_valid(event_valid), .event_ready(event_ready),
        .event_on(event_on), .event_note(event_note),
        .event_velocity(event_velocity), .event_timbre(event_timbre),
        .fifo_level(fifo_level), .fifo_full(fifo_full),
        .throttle_level(throttle_level), .throttle_pulse(throttle_pulse),
        .throttle_count(throttle_count),
        .pushed_count(pushed_count), .event_count(event_count)
    );

    // --- Allocator model, from the published contract only -----------------
    // event_ready is high only while IDLE. Accepting an event costs
    // SCAN + DECIDE + SEND, and done_valid preempts the allocator even from
    // IDLE. done_gate injects that preemption on demand.
    reg [7:0] busy = 0;
    reg done_gate = 0;
    // event_ready depends only on the model's own state, never on event_valid.
    // That is the combinational constraint interaction_top documents; the
    // real allocator satisfies it too.
    wire alloc_ready = rst_n && (busy == 0) && !done_gate;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) busy <= 0;
        else if (event_valid && event_ready) busy <= BUSY_CYCLES;
        else if (busy != 0) busy <= busy - 1;
    end

    always @(*) event_ready = alloc_ready;

    wire [EV_WIDTH-1:0] event_payload = {event_on, event_note, event_velocity, event_timbre};

    reg [EV_WIDTH-1:0] expected [0:MAXQ-1];
    reg [EV_WIDTH-1:0] last_delivered = 0;
    integer pushed = 0, delivered = 0;
    integer stall_cycles = 0, stall_episodes = 0;
    integer p0, d0, c0;
    integer ev_throttle = 0, ev_episodes = 0, ev_stall_cycles = 0;
    integer k, n;

    // --- Checks ------------------------------------------------------------
    always @(posedge clk) if (rst_n) begin
        if (in_valid && in_ready) begin
            if (pushed >= MAXQ) $fatal(1, "interaction scoreboard overflow");
            expected[pushed] = {in_on, in_note, in_velocity, in_timbre};
            pushed = pushed + 1;
        end
        if (event_valid && event_ready) begin
            if (delivered >= pushed)
                $fatal(1, "interaction delivered an event that was never presented");
            if (event_payload !== expected[delivered])
                $fatal(1, "interaction event %0d mismatch: expected %h got %h",
                       delivered, expected[delivered], event_payload);
            last_delivered = event_payload;
            delivered = delivered + 1;
        end
    end

    // The DUT's obligation: hold valid and every payload bit while stalled.
    reg prev_stall = 0;
    reg [EV_WIDTH-1:0] held_payload = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_stall = 0;
            held_payload = 0;
        end else begin
            if (event_valid !== 1'b0 && event_valid !== 1'b1)
                $fatal(1, "event_valid is X/Z");
            if (prev_stall && (event_valid !== 1'b1 || event_payload !== held_payload))
                $fatal(1, "DUT violated ready/valid stability on the event side");
            prev_stall = event_valid && !event_ready;
            held_payload = event_payload;
        end
    end

    // The stimulus side of the same rule. A failure here means THIS FILE is
    // wrong, not the DUT, and the distinction is worth keeping explicit.
    reg stim_prev_stall = 0;
    reg [EV_WIDTH-1:0] stim_held = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stim_prev_stall = 0;
            stim_held = 0;
        end else begin
            if (stim_prev_stall && (in_valid !== 1'b1 ||
                {in_on, in_note, in_velocity, in_timbre} !== stim_held))
                $fatal(1, "TESTBENCH adapter violated its own hold rule");
            stim_prev_stall = in_valid && !in_ready;
            stim_held = {in_on, in_note, in_velocity, in_timbre};
        end
    end

    // Telemetry conservation, expressed entirely through public ports:
    // pushed_count == event_count + fifo_level. A silently dropped release
    // event, which is what leaves a note stuck, breaks this identity.
    always @(negedge clk) begin
      #1; // Inputs are driven on negedge; avoid an active-region race.
      if (rst_n) begin
        if (pushed_count !== pushed)
            $fatal(1, "pushed_count=%0d but %0d pushes were accepted", pushed_count, pushed);
        if (event_count !== delivered)
            $fatal(1, "event_count=%0d but %0d events were delivered", event_count, delivered);
        if (pushed_count !== event_count + fifo_level)
            $fatal(1, "conservation broken: pushed=%0d event=%0d level=%0d",
                   pushed_count, event_count, fifo_level);
        if (fifo_full !== (fifo_level === DEPTH))
            $fatal(1, "fifo_full disagrees with fifo_level=%0d", fifo_level);
        if (throttle_level !== (in_valid && !in_ready))
            $fatal(1, "throttle_level does not track the raw stall condition");
    end

      end

    // Counted on the same edge, and from the same signal, as the DUT's own
    // counters. Sampling these on the negedge instead would put the reference
    // half a cycle ahead and turn an exact comparison into a tolerant one.
    always @(posedge clk) if (rst_n) begin
        if (throttle_level) stall_cycles = stall_cycles + 1;
        if (throttle_pulse) stall_episodes = stall_episodes + 1;
    end

    // --- Stimulus ----------------------------------------------------------
    task automatic mark(input integer id);
        begin
            $display("  INTEGRATION case %0d", id);
        end
    endtask

    // Present one event, keep it presented until it is accepted, then release
    // valid only at a point where nothing is being withdrawn.
    task automatic send_in(input bit on_v, input integer note_v,
                           input integer vel_v, input integer timb_v);
        begin
            @(negedge clk);
            in_valid = 1; in_on = on_v;
            in_note = note_v[6:0];
            in_velocity = vel_v[6:0];
            in_timbre = timb_v[1:0];
            do @(posedge clk); while (!in_ready);
            @(negedge clk);
            in_valid = 0;
        end
    endtask

    // Present an event and leave valid high. Used where the test needs to
    // hold an event in the adapter's hand across a stall.
    task automatic start_in(input bit on_v, input integer note_v,
                            input integer vel_v, input integer timb_v);
        begin
            @(negedge clk);
            in_valid = 1; in_on = on_v;
            in_note = note_v[6:0];
            in_velocity = vel_v[6:0];
            in_timbre = timb_v[1:0];
        end
    endtask

    // Adapter plays a burst: valid stays high and the next event is presented
    // only after the previous one was accepted, which is what makes a chord
    // arrive as a burst without ever violating the hold rule.
    task automatic burst(input integer count, input bit on_v, input integer note_base);
        integer i;
        begin
            @(negedge clk);
            in_valid = 1;
            in_on = on_v;
            in_note = note_base[6:0];
            in_velocity = 7'd127;
            in_timbre = 2'd1;
            i = 0;
            while (i < count) begin
                @(posedge clk);
                if (in_ready) begin
                    i = i + 1;
                    @(negedge clk);
                    if (i < count) begin
                        // The transfer completed on the edge just gone, so the
                        // payload is free to move now even if the queue filled
                        // up and in_ready has since dropped.
                        in_note = (note_base + i) & 7'h7f;
                        in_velocity = 127 - i;
                    end else begin
                        // Release valid immediately. Holding it here would
                        // present an event that was already accepted, and then
                        // withdrawing it once in_ready rose would be a genuine
                        // protocol violation, not a harmless formality.
                        in_valid = 0;
                    end
                end
            end
        end
    endtask

    // The allocator model needs BUSY_CYCLES to go idle after every event, so a
    // test that wants to offer it readiness has to wait for it first. drain()
    // returns as soon as the queue empties, which is one cycle after the last
    // event was accepted, and the model is still busy at that point.
    task automatic wait_alloc_idle;
        begin
            while (busy != 0) @(negedge clk);
        end
    endtask

    task automatic drain;
        integer guard;
        begin
            guard = 0;
            while ((pushed_count != event_count) || (fifo_level != 0)) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 200000) $fatal(1, "interaction drain timeout");
            end
        end
    endtask

    initial begin
        #1 rst_n = 1;
        #1 rst_n = 0; // Assert reset before the first rising clock edge.
        @(negedge clk);
        rst_n = 0;
        in_valid = 0;
        done_gate = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;

        // I1: a 16-note chord arrives as a burst. Order must survive and
        // nothing may be dropped, which is the whole reason the queue exists.
        mark(1);
        burst(16, 1'b1, 36);
        drain();
        if (pushed !== 16 || delivered !== 16)
            $fatal(1, "chord burst: pushed=%0d delivered=%0d", pushed, delivered);
        if (fifo_level !== 0) $fatal(1, "chord burst left %0d events queued", fifo_level);

        // I2: the allocator is gated for a long time. Gating the allocator does
        // NOT gate the queue: the whole point of the FIFO is that it keeps
        // accepting events and holds them. So the queue is filled first, and
        // only then is a fresh event left waiting in the adapter's hand.
        mark(2);
        @(negedge clk);
        done_gate = 1;
        burst(DEPTH - 1, 1'b1, 40);
        if (fifo_level !== DEPTH - 1)
            $fatal(1, "setup: queue reached %0d, wanted %0d", fifo_level, DEPTH - 1);
        @(negedge clk);
        in_valid = 1; in_on = 1'b0;
        in_note = 7'd55; in_velocity = 7'd80; in_timbre = 2'd1;
        do @(posedge clk); while (!in_ready);
        @(negedge clk);
        if (fifo_level !== DEPTH)
            $fatal(1, "setup: queue reached %0d, wanted full", fifo_level);
        // The transfer above completed on that edge, so changing the payload
        // now is legal. From here it is held bit-stable for the whole stall.
        in_note = 7'd56; in_velocity = 7'd81;
        p0 = pushed; d0 = delivered;
        repeat (300) @(negedge clk);
        if (throttle_level !== 1'b1)
            $fatal(1, "no stall was reported across a 300-cycle gate");
        if (in_valid !== 1'b1)
            $fatal(1, "adapter dropped valid during a stall");
        if (pushed !== p0 || delivered !== d0)
            $fatal(1, "events moved while the queue was full and the allocator gated");
        if (fifo_level !== DEPTH)
            $fatal(1, "queue level moved to %0d while gated and full", fifo_level);
        if ({in_on, in_note, in_velocity, in_timbre} !== {1'b0, 7'd56, 7'd81, 2'd1})
            $fatal(1, "adapter payload moved during the stall");
        // Release the gate: the blocked event must land, not be abandoned.
        done_gate = 0;
        do @(posedge clk); while (!in_ready);
        @(negedge clk);
        in_valid = 0;
        drain();
        if (delivered !== pushed) $fatal(1, "the gated event was lost");
        if (last_delivered !== {1'b0, 7'd56, 7'd81, 2'd1})
            $fatal(1, "the gated event came through as %h", last_delivered);

        // I3: the allocator is offered exactly one cycle of readiness. One
        // event may cross, not zero and not two, which is what pins the
        // handshake to edge precision rather than to a level.
        mark(3);
        @(negedge clk);
        done_gate = 1;
        burst(4, 1'b1, 72);
        wait_alloc_idle();
        if (fifo_level !== 4) $fatal(1, "window setup: level=%0d", fifo_level);
        p0 = pushed; d0 = delivered;
        @(negedge clk);
        done_gate = 0;
        @(negedge clk);
        done_gate = 1;
        @(negedge clk);
        if (delivered !== d0 + 1)
            $fatal(1, "a one-cycle ready window delivered %0d events", delivered - d0);
        if (fifo_level !== 3)
            $fatal(1, "a one-cycle ready window moved the level to %0d", fifo_level);
        done_gate = 0;
        drain();
        if (delivered !== pushed) $fatal(1, "events were lost after the window");

        // I5: velocity 0 must cross this layer untouched. Translating it into
        // a note-off here is the allocator's job, not this module's, and doing
        // it twice is how a legitimate silent note loses its release.
        mark(5);
        send_in(1'b1, 7'd64, 7'd0, 2'd2);
        drain();
        if (last_delivered !== {1'b1, 7'd64, 7'd0, 2'd2})
            $fatal(1, "velocity 0 was rewritten to %h", last_delivered);

        // I6: telemetry must be readable and consistent while the queue is
        // actually loaded, not only when it is at rest.
        mark(6);
        burst(20, 1'b1, 60);
        @(negedge clk);
        if (fifo_level == 0)
            $fatal(1, "telemetry reported an empty queue during a 20-event burst");
        if (pushed_count !== pushed)
            $fatal(1, "pushed_count disagrees with the scoreboard mid-burst");
        drain();
        if (fifo_level !== 0 || pushed_count !== event_count)
            $fatal(1, "telemetry did not settle after drain");

        // I7: throttle_level is a level that persists for the whole stall, so
        // a counter fed the raw level would over-count by the ~66 cycles each
        // stall lasts. throttle_count must move once per stall EPISODE.
        mark(7);
        stall_cycles = 0;
        stall_episodes = 0;
        c0 = throttle_count;
        burst(DEPTH * 2, 1'b1, 40);
        drain();
        if (stall_cycles < 100)
            $fatal(1, "a %0d-event overload never stalled the adapter", DEPTH * 2);
        if (throttle_count <= c0)
            $fatal(1, "throttle_count never moved during an overload");
        if (throttle_count - c0 !== stall_episodes)
            $fatal(1, "throttle_count moved %0d times over %0d stall episodes",
                   throttle_count - c0, stall_episodes);
        // A counter fed the level instead of the pulse would land near
        // stall_cycles. Requiring it to stay far below is what makes this
        // case falsifiable rather than merely present.
        if (throttle_count - c0 > stall_cycles / 4)
            $fatal(1, "throttle_count=%0d tracks stall cycles=%0d: level and pulse are conflated",
                   throttle_count - c0, stall_cycles);
        // Captured here because I8 resets the DUT and would zero these, which
        // would make the summary line below report empty evidence.
        ev_throttle = throttle_count - c0;
        ev_episodes = stall_episodes;
        ev_stall_cycles = stall_cycles;
        $display("  THROTTLE EVIDENCE: count +%0d, episodes %0d, stalled cycles %0d",
                 ev_throttle, ev_episodes, ev_stall_cycles);

        // I8: reset in the middle of a loaded queue. Everything this module
        // owns must clear, and the path must work again afterwards.
        mark(8);
        burst(4, 1'b1, 48);
        @(negedge clk);
        rst_n = 0;
        repeat (3) @(negedge clk);
        if (fifo_level !== 0 || event_valid !== 1'b0)
            $fatal(1, "interaction reset did not clear the queue");
        if (pushed_count !== 0 || event_count !== 0 || throttle_count !== 0)
            $fatal(1, "interaction reset did not clear the telemetry");
        rst_n = 1;
        in_valid = 0;
        pushed = 0; delivered = 0;
        repeat (2) @(negedge clk);
        burst(4, 1'b1, 48);
        drain();
        if (pushed !== 4 || delivered !== 4)
            $fatal(1, "interaction did not recover after reset: pushed=%0d delivered=%0d",
                   pushed, delivered);

        // I9: a release burst. Losing a release is what leaves a note stuck
        // forever, and the allocator has no all-notes-off, so this is the
        // failure mode that matters most and gets its own case.
        mark(9);
        burst(16, 1'b1, 36);
        drain();
        n = pushed;
        burst(16, 1'b0, 36);
        drain();
        if (pushed !== n + 16 || delivered !== pushed)
            $fatal(1, "release burst lost an event: pushed=%0d delivered=%0d", pushed, delivered);
        for (k = n; k < pushed; k = k + 1)
            if (expected[k][16] !== 1'b0)
                $fatal(1, "release burst event %0d carried a note-on", k);

        $display("INTERACTION CASE PASSED DEPTH=%0d pushed=%0d delivered=%0d throttle_count=+%0d over %0d episodes (%0d stalled cycles)",
                 DEPTH, pushed, delivered, ev_throttle, ev_episodes, ev_stall_cycles);
        finished = 1;
    end
endmodule

module tb_interaction;
    wire finished_edge, finished_default, finished_integration;
    fifo_case #(.DEPTH(2),  .AWIDTH(1)) depth_edge_case (finished_edge);
    fifo_case #(.DEPTH(32), .AWIDTH(5)) depth_default_case (finished_default);
    interaction_case #(.DEPTH(32), .AWIDTH(5)) integration_case (finished_integration);

    initial begin
        wait (finished_edge && finished_default && finished_integration);
        $display("ALL INTERACTION TESTS PASSED");
        $finish;
    end
    initial begin
        #5000000;
        $fatal(1, "interaction watchdog expired");
    end
endmodule
