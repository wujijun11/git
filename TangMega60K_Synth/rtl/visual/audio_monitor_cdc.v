// Coherent stereo mailbox. The audio producer never waits for visualization.
// Bundled sample data remains stable until the destination acknowledges it.
module audio_monitor_cdc (
    input wire src_clk,src_rst_n,src_valid,
    input wire signed [23:0] src_left,src_right,
    output reg [31:0] drop_count,
    input wire dst_clk,dst_rst_n,
    output reg dst_valid,output reg signed [23:0] dst_left,dst_right
);
    reg req,ack;
    reg ack_meta,ack_sync,req_meta,req_sync;
    reg [47:0] bundle;
    always @(posedge src_clk or negedge src_rst_n)begin
        if(!src_rst_n)begin req<=0;ack_meta<=0;ack_sync<=0;bundle<=0;drop_count<=0;end
        else begin
            ack_meta<=ack;ack_sync<=ack_meta;
            if(src_valid)begin
                if(req==ack_sync)begin bundle<={src_left,src_right};req<=!req;end
                else drop_count<=drop_count+1'b1;
            end
        end
    end
    always @(posedge dst_clk or negedge dst_rst_n)begin
        if(!dst_rst_n)begin ack<=0;req_meta<=0;req_sync<=0;dst_valid<=0;dst_left<=0;dst_right<=0;end
        else begin
            req_meta<=req;req_sync<=req_meta;dst_valid<=0;
            if(req_sync!=ack)begin
                {dst_left,dst_right}<=bundle;dst_valid<=1;ack<=req_sync;
            end
        end
    end
endmodule
