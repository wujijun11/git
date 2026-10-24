// Fixed 16-note diagnostic event producer; all logic is synthesizable HDL.
// MIDI 60..75, sine timbre, velocity 100. Sine notes sustain until stop.
// Inputs must be synchronous to clk. This producer owns the allocator while
// busy; reset must reset this source, the allocator, engine and event queues.
module poly16_event_source (
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
    localparam IDLE=3'd0, SEND_ON=3'd1, SETTLE=3'd2,
               HOLD=3'd3, SEND_OFF=3'd4, DRAIN=3'd5;
    reg [2:0] state;
    reg start_previous, stop_pending;
    reg [3:0] note_index;
    reg [4:0] sent_count;
    wire start_edge=start && !start_previous;
    wire abort_now=stop || stop_pending || allocation_error;
    assign busy=rst_n && state!=IDLE;
    assign holding=rst_n && state==HOLD;
    assign start_ready=rst_n && state==IDLE && active_count==0 && event_ready && !stop;
    assign event_valid=rst_n && (state==SEND_ON || state==SEND_OFF);
    assign event_on=state==SEND_ON;
    assign event_source=6'd63;
    assign event_note=7'd60+{3'd0,note_index};
    assign event_velocity=7'd100;
    assign event_timbre=2'd0;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; start_previous<=0; stop_pending<=0;
            note_index<=0; sent_count<=0; released_pulse<=0; error<=0;
        end else begin
            start_previous<=start;
            released_pulse<=0;
            if(state!=IDLE && (stop || allocation_error)) stop_pending<=1;
            if(allocation_error && state!=IDLE) error<=1;
            case(state)
                IDLE: begin
                    stop_pending<=0;
                    // Ignore starts while busy; a held start never restarts
                    // after a stop. Start only with an empty allocator.
                    if(start_edge && !stop) begin
                        if(start_ready) begin
                            state<=SEND_ON; note_index<=0; sent_count<=0; error<=0;
                        end else error<=1;
                    end
                end
                SEND_ON: if(event_ready) begin
                    sent_count<=sent_count+1'b1;
                    // Keep stalled valid/payload stable even after stop.
                    // Accept that note once, then release every accepted note.
                    if(abort_now) begin note_index<=0; state<=SEND_OFF; end
                    else if(note_index==4'd15) state<=SETTLE;
                    else note_index<=note_index+1'b1;
                end
                SETTLE: begin
                    // Direct audio-system ready implies prior event applied.
                    // Accepted event counts alone do not prove 16 voices.
                    if(abort_now) begin note_index<=0; state<=SEND_OFF; end
                    else if(event_ready) begin
                        if(active_count==7'd16) state<=HOLD;
                        else begin error<=1; note_index<=0; state<=SEND_OFF; end
                    end
                end
                HOLD: if(abort_now) begin note_index<=0; state<=SEND_OFF; end
                SEND_OFF: if(event_ready) begin
                    if({1'b0,note_index}+5'd1==sent_count) state<=DRAIN;
                    else note_index<=note_index+1'b1;
                end
                DRAIN: if(event_ready && active_count==0) begin
                    state<=IDLE; released_pulse<=1;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
