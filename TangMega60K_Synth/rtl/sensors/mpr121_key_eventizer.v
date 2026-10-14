// Complete transition batches are serialized into a reserved event FIFO.
// Pollers are backpressured before accepting a batch; releases are never overwritten.
module mpr121_key_eventizer #(
    parameter integer FIFO_DEPTH=64,
    parameter integer SOURCE_BASE=25
)(
    input wire clk,resetn, input wire [2:0] snapshot_valid,
    output reg [2:0] snapshot_ready,
    input wire [7:0] touch0,touch1, input wire [8:0] touch2,
    input wire [2:0] fault,
    input wire [174:0] key_map_flat, input wire [1:0] current_timbre,
    output wire key_valid, input wire key_ready,
    output wire key_on,output wire [5:0] key_source,
    output wire [6:0] key_note,key_velocity,output wire [1:0] key_timbre,
    output reg [24:0] touch_mask,
    output reg overflow,output wire [15:0] pending_events
);
    localparam integer PW=$clog2(FIFO_DEPTH);
    reg [22:0] fifo [0:FIFO_DEPTH-1];
    reg [PW-1:0] wrptr,rdptr;
    reg [PW:0] count;
    reg [24:0] committed,target;
    reg [6:0] held_note[0:24];reg [1:0] held_timbre[0:24];
    reg [174:0] batch_map;reg [1:0] batch_timbre;
    reg scanning;reg [4:0] scan_key;
    reg [2:0] fault_seen,release_pending;
    reg [1:0] round_robin;
    reg [1:0] choice;
    wire pop=key_valid && key_ready;
    wire scan_changed=scanning && (target[scan_key]!=committed[scan_key]);
    // A complete batch reserves capacity before scanning. Keep the write path
    // independent of downstream ready: pop can traverse the entire arbiter.
    // If capacity is ever exhausted, retain this transition until count drops.
    wire push=scan_changed && (count<FIFO_DEPTH);
    wire [22:0] head=fifo[rdptr];
    wire [5:0] event_source=SOURCE_BASE+scan_key;
    assign key_valid=(count!=0);
    assign {key_on,key_source,key_note,key_velocity,key_timbre}=head;
    assign pending_events=count;
    integer k;
    always @* begin
        choice=3; snapshot_ready=0;
        // One normal module snapshot can change at most nine keys.
        // Fault batches may cover all 25 keys and reserve separately below.
        if(!scanning && count<=FIFO_DEPTH-9 && release_pending==0) begin
            case(round_robin)
            0: if(snapshot_valid[0]) choice=0;else if(snapshot_valid[1]) choice=1;else if(snapshot_valid[2]) choice=2;
            1: if(snapshot_valid[1]) choice=1;else if(snapshot_valid[2]) choice=2;else if(snapshot_valid[0]) choice=0;
            default: if(snapshot_valid[2]) choice=2;else if(snapshot_valid[0]) choice=0;else if(snapshot_valid[1]) choice=1;
            endcase
            if(choice!=3) snapshot_ready[choice]=1;
        end
    end
    always @(posedge clk) begin
        if(!resetn) begin
            wrptr<=0;rdptr<=0;count<=0;committed<=0;target<=0;touch_mask<=0;
            scanning<=0;scan_key<=0;fault_seen<=0;release_pending<=0;
            round_robin<=0;overflow<=0;batch_map<=0;batch_timbre<=0;
            for(k=0;k<25;k=k+1) begin held_note[k]<=0;held_timbre[k]<=0;end
        end else begin
            fault_seen<=fault;
            release_pending<=release_pending | (fault & ~fault_seen);
            if(pop) rdptr<=(rdptr==FIFO_DEPTH-1)?0:rdptr+1;
            if(scan_changed && count==FIFO_DEPTH && !pop) overflow<=1;
            if(push) begin
                fifo[wrptr]<={target[scan_key],event_source,
                    target[scan_key]?batch_map[scan_key*7 +:7]:held_note[scan_key],
                    7'd100,target[scan_key]?batch_timbre:held_timbre[scan_key]};
                wrptr<=(wrptr==FIFO_DEPTH-1)?0:wrptr+1;
                committed[scan_key]<=target[scan_key];
                if(target[scan_key]) begin
                    held_note[scan_key]<=batch_map[scan_key*7 +:7];held_timbre[scan_key]<=batch_timbre;
                end
            end
            case({push,pop})
                2'b10:count<=count+1;
                2'b01:count<=count-1;
                default:count<=count;
            endcase
            if(scanning) begin
                if(!scan_changed || count<FIFO_DEPTH) begin
                    if(scan_key==24) scanning<=0;
                    else scan_key<=scan_key+1;
                end
            end else begin
                if(release_pending!=0 && count<=FIFO_DEPTH-25) begin
                    if(release_pending[0]) begin target[7:0]<=0;touch_mask[7:0]<=0;end
                    if(release_pending[1]) begin target[15:8]<=0;touch_mask[15:8]<=0;end
                    if(release_pending[2]) begin target[24:16]<=0;touch_mask[24:16]<=0;end
                    release_pending<=fault & ~fault_seen;
                    scanning<=1;scan_key<=0;
                end else if(choice!=3) begin
                    case(choice)
                    0:begin target[7:0]<=fault[0]?0:touch0;touch_mask[7:0]<=fault[0]?0:touch0;end
                    1:begin target[15:8]<=fault[1]?0:touch1;touch_mask[15:8]<=fault[1]?0:touch1;end
                    2:begin target[24:16]<=fault[2]?0:touch2;touch_mask[24:16]<=fault[2]?0:touch2;end
                    endcase
                    batch_map<=key_map_flat;batch_timbre<=current_timbre;
                    scanning<=1;scan_key<=0;round_robin<=(choice==2)?0:choice+1;
                end
            end
        end
    end
endmodule
