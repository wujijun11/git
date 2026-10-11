// BLE may disappear before delivering a key release. Only the phone's source
// is released after timeout; physical keys and the offline score keep playing.
module remote_note_watchdog #(
    parameter CLK_HZ=49152000, TIMEOUT_SECONDS=3
) (
    input wire clk,rst_n,heartbeat,expire,
    input wire accepted,input wire accepted_on,input wire [6:0] accepted_note,
    output reg event_valid,input wire event_ready,
    output wire event_on,output wire [5:0] event_source,
    output reg [6:0] event_note,output wire [6:0] event_velocity,
    output wire [1:0] event_timbre,output reg releasing,
    output reg [31:0] timeout_count
);
    reg [127:0] held;
    reg [31:0] silence;
    reg [7:0] scan;
    assign event_on=0;assign event_source=63;assign event_velocity=0;assign event_timbre=0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            held<=0;silence<=0;scan<=0;event_valid<=0;event_note<=0;releasing<=0;timeout_count<=0;
        end else begin
            if(heartbeat) silence<=0;
            else if(|held && !releasing) silence<=silence+1'b1;
            else silence<=0;
            if(accepted)held[accepted_note]<=accepted_on;
            if(!releasing && |held && (expire || (!heartbeat && silence==CLK_HZ*TIMEOUT_SECONDS-1))) begin
                releasing<=1;scan<=0;silence<=0;timeout_count<=timeout_count+1'b1;
            end
            if(releasing) begin
                if(event_valid) begin
                    if(event_ready)begin held[event_note]<=0;event_valid<=0;scan<=scan+1'b1;end
                end else if(scan==128)begin
                    if(|held || (accepted && accepted_on))scan<=0;
                    else releasing<=0;
                end
                else if(held[scan[6:0]])begin event_valid<=1;event_note<=scan[6:0];end
                else scan<=scan+1'b1;
            end
        end
    end
endmodule
