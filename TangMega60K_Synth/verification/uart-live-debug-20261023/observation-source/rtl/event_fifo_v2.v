// Teammate B V2 event queue. Verilog-2001.
// One 23-bit event per entry:
//   {on, source[5:0], note[6:0], velocity[6:0], timbre[1:0]}
//
// The V2 captain still accepts one note event at a time and can be busy for
// the allocator scan. This FIFO preserves order and applies backpressure
// instead of silently dropping a release.
module event_fifo_v2 #(
    parameter integer DEPTH = 32,
    parameter integer AWIDTH = 5,
    parameter integer SOURCE_WIDTH = 6
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    push_valid,
    output wire                    push_ready,
    input  wire                    push_on,
    input  wire [SOURCE_WIDTH-1:0] push_source,
    input  wire [6:0]              push_note,
    input  wire [6:0]              push_velocity,
    input  wire [1:0]              push_timbre,
    output wire                    pop_valid,
    input  wire                    pop_ready,
    output wire                    pop_on,
    output wire [SOURCE_WIDTH-1:0] pop_source,
    output wire [6:0]              pop_note,
    output wire [6:0]              pop_velocity,
    output wire [1:0]              pop_timbre,
    output wire [AWIDTH:0]         level,
    output wire                    full,
    output wire                    empty
);
    localparam integer EV_WIDTH = 1 + SOURCE_WIDTH + 7 + 7 + 2;

    // Keep an explicit whole-event synchronous RAM read boundary. Gowin
    // 1.9.12 incorrectly compacted a partial read when this queue's old
    // asynchronous read was absorbed into the allocator (note became
    // velocity). A register-only queue avoids that bug but misses 49.152MHz
    // timing in the full main project. Preserve this packed RAM output and
    // use a separate bypass for an empty queue; no RAM contents need reset.
    reg [EV_WIDTH-1:0] mem [0:DEPTH-1] /* synthesis syn_ramstyle = "block_ram" */;
    reg [EV_WIDTH-1:0] ram_head /* synthesis syn_preserve = 1 */;
    reg [EV_WIDTH-1:0] bypass_head;
    reg head_valid, head_from_ram;
    reg [AWIDTH-1:0] wptr, rptr;
    reg [AWIDTH:0] count, ram_count;

    wire do_push = push_valid && push_ready;
    wire do_pop  = pop_valid && pop_ready;
    wire head_free = !head_valid || pop_ready;
    wire read_ram = rst_n && head_free && (ram_count != 0);
    wire bypass = do_push && head_free && (ram_count == 0);
    wire write_ram = do_push && !bypass;
    wire [EV_WIDTH-1:0] push_payload =
        {push_on, push_source, push_note, push_velocity, push_timbre};
    wire [EV_WIDTH-1:0] head = !head_valid ? {EV_WIDTH{1'b0}} :
        (head_from_ram ? ram_head : bypass_head);

    assign push_ready = rst_n && (count != DEPTH);
    assign full  = rst_n && (count == DEPTH);
    assign empty = !rst_n || (count == 0);
    assign level = count;

    assign pop_valid    = rst_n && head_valid;
    assign pop_on       = head[EV_WIDTH-1];
    assign pop_source   = head[EV_WIDTH-2 -: SOURCE_WIDTH];
    assign pop_note     = head[15:9];
    assign pop_velocity = head[8:2];
    assign pop_timbre   = head[1:0];

    // Read and write addresses differ whenever both enables are asserted:
    // the oldest queued RAM word was written before it can be prefetched.
    always @(posedge clk) begin
        if (write_ram) mem[wptr] <= push_payload;
        if (read_ram) ram_head <= mem[rptr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr  <= 0;
            rptr  <= 0;
            count <= 0;
            ram_count <= 0;
            head_valid <= 0;
            head_from_ram <= 0;
            bypass_head <= 0;
        end else begin
            if (head_free) begin
                head_valid <= read_ram || bypass;
                head_from_ram <= read_ram;
            end
            if (bypass) bypass_head <= push_payload;
            if (write_ram) begin
                wptr <= wptr + 1'b1;
            end
            if (read_ram)
                rptr <= rptr + 1'b1;
            case ({write_ram, read_ram})
                2'b10:   ram_count <= ram_count + 1'b1;
                2'b01:   ram_count <= ram_count - 1'b1;
                default: ram_count <= ram_count;
            endcase
            case ({do_push, do_pop})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule
