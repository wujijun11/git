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

    reg [EV_WIDTH-1:0] mem [0:DEPTH-1];
    reg [AWIDTH-1:0] wptr, rptr;
    reg [AWIDTH:0] count;
    integer i;

    wire do_push = push_valid && push_ready;
    wire do_pop  = pop_valid && pop_ready;

    assign push_ready = rst_n && (count != DEPTH);
    assign full  = rst_n && (count == DEPTH);
    assign empty = !rst_n || (count == 0);
    assign level = count;

    assign pop_valid    = rst_n && !empty;
    assign pop_on       = mem[rptr][EV_WIDTH-1];
    assign pop_source   = mem[rptr][EV_WIDTH-2 -: SOURCE_WIDTH];
    assign pop_note     = mem[rptr][15:9];
    assign pop_velocity = mem[rptr][8:2];
    assign pop_timbre   = mem[rptr][1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr  <= 0;
            rptr  <= 0;
            count <= 0;
            for (i = 0; i < DEPTH; i = i + 1)
                mem[i] <= 0;
        end else begin
            if (do_push) begin
                mem[wptr] <= {push_on, push_source, push_note, push_velocity, push_timbre};
                wptr <= wptr + 1'b1;
            end
            if (do_pop)
                rptr <= rptr + 1'b1;
            case ({do_push, do_pop})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule
