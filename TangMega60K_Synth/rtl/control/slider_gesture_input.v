// 滑条手势采集：短触松手、左/右长按与连续位置分开输出。
// position单位0..3072；计时参数单位为clk周期。故障取消手势，不当作松手。
// 菜单事件使用单项ready/valid，反压期间负载不变；一次长按只产生一次事件。
module slider_gesture_input #(
    parameter integer DEBOUNCE_CYCLES=983040,
    parameter integer LONG_PRESS_CYCLES=49152000,
    parameter integer HYSTERESIS=48
)(
    input wire clk,rst_n,touch_active,touch_fault,
    input wire [11:0] position,
    input wire continuous_mode,waveform_view,
    output reg event_valid,input wire event_ready,
    output reg [1:0] event_kind, // 0短触，1左长按，2右长按
    output reg [1:0] event_zone,
    output wire [1:0] preview_zone,
    output wire position_valid,output wire [11:0] control_position
);
    localparam integer DB=DEBOUNCE_CYCLES>0?DEBOUNCE_CYCLES:1;
    localparam integer LP=LONG_PRESS_CYCLES>0?LONG_PRESS_CYCLES:1;
    localparam integer CW=$clog2(DB+LP+2)>0?$clog2(DB+LP+2):1;
    reg previous_touch,blocked,long_fired,stable,left_reserved,wake_gesture;
    reg [1:0] candidate;
    reg [CW-1:0] stable_count,long_count;
    reg release_position;
    reg [11:0] last_position;
    wire space=!event_valid || event_ready;
    wire [1:0] raw_zone=position<768?0:position<1536?1:position<2304?2:3;
    wire in_zone=candidate==0?position<768+HYSTERESIS:
        candidate==1?position>=768-HYSTERESIS && position<1536+HYSTERESIS:
        candidate==2?position>=1536-HYSTERESIS && position<2304+HYSTERESIS:
        position>=2304-HYSTERESIS;
    assign preview_zone=candidate;
    assign position_valid=!touch_fault && (release_position ||
        (continuous_mode && touch_active && stable && !blocked && !long_fired && !left_reserved));
    assign control_position=release_position?last_position:position;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            event_valid<=0;
            event_kind<=0;
            event_zone<=0;
            previous_touch<=0;
            blocked<=0;
            long_fired<=0;
            stable<=0;
            left_reserved<=0;
            wake_gesture<=0;
            candidate<=0;
            stable_count<=0;
            long_count<=0;
            release_position<=0;
            last_position<=0;
        end else begin
            previous_touch<=touch_active;
            release_position<=0;
            if(event_valid && event_ready)event_valid<=0;
            if(touch_active && !touch_fault)last_position<=position;
            if(touch_fault)begin
                previous_touch<=0;
                blocked<=1;
                stable<=0;
                long_fired<=0;
                stable_count<=0;
                long_count<=0;
                left_reserved<=0;
                wake_gesture<=0;
            end else if(touch_active && !previous_touch)begin
                candidate<=raw_zone;
                stable_count<=0;
                long_count<=0;
                stable<=0;
                blocked<=!space;
                long_fired<=0;
                // 波形唤醒的整次手势只调连续参数，避免左端一碰就又打开菜单。
                wake_gesture<=waveform_view;
                left_reserved<=continuous_mode && position<=128 && !waveform_view;
            end else if(touch_active && !blocked && !long_fired)begin
                if(!continuous_mode && !in_zone)begin
                    candidate<=raw_zone;
                    stable_count<=0;
                    long_count<=0;
                    stable<=0;
                end else if(!stable)begin
                    if(stable_count>=DB-1)begin stable<=1;
                    long_count<=0;
                    end
                    else stable_count<=stable_count+1'b1;
                    if(continuous_mode)left_reserved<=position<=128 && !wake_gesture;
                end else if(continuous_mode && left_reserved && position>128+HYSTERESIS)begin
                    left_reserved<=0;
                    long_count<=0;
                end else if(!wake_gesture && (continuous_mode?left_reserved:(candidate==0 || candidate==3)))begin
                    if(long_count>=LP-1 && space)begin
                        event_valid<=1;
                        event_kind<=candidate==3 && !continuous_mode?2:1;
                        event_zone<=candidate;
                        long_fired<=1;
                    end else if(long_count<LP-1)long_count<=long_count+1'b1;
                end
            end
            if(!touch_fault && !touch_active && previous_touch)begin
                if(!blocked && !long_fired && stable && space)begin
                    if(continuous_mode)release_position<=1;
                    else begin event_valid<=1;
                    event_kind<=0;
                    event_zone<=candidate;
                    end
                end
                stable<=0;
                blocked<=0;
                stable_count<=0;
                long_count<=0;
                wake_gesture<=0;
            end
        end
    end
endmodule
