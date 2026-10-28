// 四区分层导航。只发既有菜单动作，不修改event/cmd/done/sample公共V2。
// 视图：0连续控制，1总菜单，2声音，3音色，4音区，5音效，6表情，7录放，8曲谱。
// 普通设置成功后显示波形并回音量；表情选择直接进入对应连续控制。
module menu_hierarchy #(
    parameter integer DEBOUNCE_CYCLES=983040,LONG_PRESS_CYCLES=49152000,
    parameter integer IDLE_CYCLES=491520000
)(
    input wire clk,rst_n,touch_active,touch_fault,input wire [11:0] position,
    output reg request_valid,input wire request_ready,
    output wire [1:0] request_kind,output reg [1:0] request_page,request_zone,
    input wire action_busy,action_done,input wire [7:0] action_error,
    output reg [7:0] display_error,
    output reg fx_write,output reg [1:0] fx_value,
    output reg expression_reset,
    output reg [3:0] view,output reg [1:0] expression_mode,
    output reg waveform_view,output wire [1:0] preview_zone,
    output wire position_valid,output wire [11:0] control_position
);
    localparam integer LIMIT=IDLE_CYCLES>0?IDLE_CYCLES:1;
    localparam integer IW=$clog2(LIMIT+1)>0?$clog2(LIMIT+1):1;
    reg [IW-1:0] idle_count;
    reg awaiting_action;
    wire gv,gr;
    wire [1:0] kind,zone;
    assign gr=!request_valid && !awaiting_action && !action_busy;
    assign request_kind=2'd0;
    slider_gesture_input #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),.LONG_PRESS_CYCLES(LONG_PRESS_CYCLES)) gestures(
        .clk(clk),.rst_n(rst_n),.touch_active(touch_active),.touch_fault(touch_fault),.position(position),
        .continuous_mode(view==0),.waveform_view(waveform_view),
        .event_valid(gv),.event_ready(gr),.event_kind(kind),.event_zone(zone),
        .preview_zone(preview_zone),.position_valid(position_valid),.control_position(control_position));
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            view<=0;
            expression_mode<=0;
            waveform_view<=0;
            idle_count<=0;
            request_valid<=0;
            request_page<=0;
            request_zone<=0;
            awaiting_action<=0;
            fx_write<=0;
            fx_value<=0;
            expression_reset<=0;
            display_error<=0;
        end else begin
            fx_write<=0;
            expression_reset<=0;
            if(touch_active || touch_fault || action_busy || display_error!=0 || request_valid || awaiting_action)begin
                idle_count<=0;
                waveform_view<=0;
            end else if(idle_count>=LIMIT-1)waveform_view<=1;
            else idle_count<=idle_count+1'b1;
            if(waveform_view && touch_active && !touch_fault)begin
                view<=0;
                waveform_view<=0;
                idle_count<=0;
                // 原来是连续表情则保留；菜单闲置或设置完成后回音量。
                if(view!=0)expression_mode<=0;
            end
            if(request_valid && request_ready)begin request_valid<=0;
            awaiting_action<=1;
            end
            if(awaiting_action && action_done)begin
                awaiting_action<=0;
                display_error<=action_error;
                if(action_error==0 && !touch_active)begin
                    view<=0;
                    expression_mode<=0;
                    waveform_view<=1;
                    idle_count<=LIMIT-1;
                end
            end
            if(gv && gr)begin
                idle_count<=0;
                waveform_view<=0;
                display_error<=0;
                if(kind==1) view<=1;
                else if(kind==2)begin view<=0;
                expression_mode<=0;
                end
                else case(view)
                    1:case(zone)0:view<=2;
                    1:view<=6;
                    2:view<=7;
                    default:view<=8;
                    endcase
                    2:case(zone)0:view<=3;
                    1:view<=4;
                    2:view<=5;
                    default:view<=1;
                    endcase
                    3,4,7,8:begin
                        request_valid<=1;
                        request_zone<=zone;
                        request_page<=view==3?0:view==4?1:view==7?2:3;
                    end
                    5:begin
                        fx_write<=1;
                        fx_value<=zone;
                        view<=0;
                        expression_mode<=0;
                        waveform_view<=1;
                        idle_count<=LIMIT-1;
                    end
                    6:begin
                        view<=0;
                        if(zone==3)begin expression_reset<=1;
                        expression_mode<=0;
                        end
                        else expression_mode<=zone;
                    end
                    default:;
                endcase
            end
        end
    end
endmodule
