// 独立I2C OLED状态屏：SSD1315/SSD1306的128x64页式显示命令。
// 刷新前锁存菜单与录放状态。没有全屏缓存，不占用音频总线或声部。
// SCL/SDA仅拉低或高阻，需外部3.3V上拉。地址为7位0x3C，可改0x3D。
// 四针模块没有外部RESET；依赖模块自身上电复位，实际型号仍须上板确认。
module oled_status_display #(
    parameter integer CLK_HZ=49152000, I2C_HZ=400000,
    parameter integer POWER_WAIT_CYCLES=CLK_HZ/10,
    parameter integer FRAME_WAIT_CYCLES=CLK_HZ/25,
    parameter [6:0] ADDRESS=7'h3c,
    parameter integer COLUMN_OFFSET=0,
    parameter FONT_FILE="rtl/audio/rom/menu_font.hex",
    parameter integer PERFORMANCE_UI_ENABLE=0,
    parameter integer HIERARCHY_UI_ENABLE=0,
    parameter integer SUSTAIN_UI_ENABLE=0,
    parameter integer WAVEFORM_ENABLE=0,
    parameter integer WAVE_IDLE_CYCLES=CLK_HZ*10,
    parameter integer WAVE_FRAME_WAIT_CYCLES=CLK_HZ/200
) (
    input wire clk,rst_n,main_menu,
    input wire [1:0] menu_page,zone,
    input wire recording,playing,guide,busy,
    input wire [7:0] error,
    input wire [15:0] record_count,
    inout wire scl,sda,
    output reg fault,
    output reg [31:0] completed_frames,
    input wire performance_mode,
    input wire [7:0] volume_percent,
    input wire ui_activity,
    input wire audio_sample_valid,
    input wire signed [23:0] audio_sample,
    input wire [3:0] hierarchy_view,
    input wire [1:0] expression_mode,
    input wire external_waveform_view,
    input wire [11:0] control_value,
    input wire control_negative,
    input wire [7:0] control_percent,
    input wire sustain_enabled
);
    localparam [3:0] POWER=0,INIT=1,SNAPSHOT=2,BCD_WAIT=3,PAGE=4,
        RENDER_WAIT=5,DATA=6,SEND=7,WAIT_DONE=8,FRAME_WAIT=9,RETRY=10;
    reg [3:0] state;
    reg [1:0] transfer_kind,page_command;
    reg [4:0] init_index;
    reg [2:0] screen_page;
    reg [6:0] column;
    reg [31:0] timer;
    reg [7:0] control_byte,payload;
    reg snap_main,snap_record,snap_play,snap_guide,snap_busy;
    reg [1:0] snap_page,snap_zone;
    reg [7:0] snap_error;
    reg [15:0] snap_count;
    reg snap_performance;
    reg [7:0] snap_volume;
    reg [3:0] snap_view;
    reg [1:0] snap_expression;
    reg [11:0] snap_control;
    reg snap_negative;
    reg [7:0] snap_percent;
    reg snap_wave;
    reg snap_sustain;
    reg bcd_start;
    reg count_done_seen,volume_done_seen;
    wire bcd_done;
    wire [15:0] digits;
    wire [15:0] volume_digits;
    wire volume_bcd_done;
    wire [7:0] pixels;
    wire [7:0] menu_pixels;
    wire [7:0] wave_pixels;
    wire waveform_idle;
    wire wave_requested = WAVEFORM_ENABLE && waveform_idle && !ui_activity && !busy && error == 0;
    wire stream_ready;
    wire [7:0] stream_data = WAVEFORM_ENABLE && transfer_kind == 2 ? pixels : payload;
    wire [7:0] stream_length = WAVEFORM_ENABLE && transfer_kind == 2 ? 8'd128 : 8'd1;
    assign pixels = snap_wave && screen_page >= 2 ? wave_pixels : menu_pixels;
    wire cmd_ready,transaction_done;
    wire [2:0] transaction_error;
    bin16_to_bcd decimal_count(.clk(clk),.rst_n(rst_n),.start(bcd_start),
        .value(snap_count),.digits(digits),.done(bcd_done));
    generate if(PERFORMANCE_UI_ENABLE) begin: volume_bcd
        bin16_to_bcd decimal_volume(.clk(clk),.rst_n(rst_n),.start(bcd_start),
            .value(HIERARCHY_UI_ENABLE?{4'd0,snap_control}:{8'd0,snap_volume}),
            .digits(volume_digits),.done(volume_bcd_done));
    end else begin: no_volume_bcd
        assign volume_digits=16'h0100;
        assign volume_bcd_done=1'b1;
    end endgenerate
    generate if(HIERARCHY_UI_ENABLE)begin: hierarchy_renderer
        oled_hierarchy_renderer #(.SUSTAIN_ENABLE(SUSTAIN_UI_ENABLE)) renderer(.clk(clk),.screen_page(screen_page),.column(column),
            .view(snap_view),.zone(snap_zone),.expression_mode(snap_expression),
            .recording(snap_record),.playing(snap_play),.guide(snap_guide),.busy(snap_busy),.error(snap_error),
            .record_digits(digits),.control_digits(volume_digits),.control_negative(snap_negative),
            .control_percent(snap_percent),.sustain_enabled(snap_sustain),.data(menu_pixels));
    end else begin: legacy_renderer
    oled_menu_renderer #(.FONT_FILE(FONT_FILE),.PERFORMANCE_UI_ENABLE(PERFORMANCE_UI_ENABLE)) renderer(
        .clk(clk),.screen_page(screen_page),.column(column),
        .main_menu(snap_main),.menu_page(snap_page),.zone(snap_zone),
        .recording(snap_record),.playing(snap_play),.guide(snap_guide),
        .busy(snap_busy),.error(snap_error),.record_digits(digits),.data(menu_pixels),
        .performance_mode(snap_performance),.volume_digits(volume_digits[11:0]),
        .volume_percent(snap_volume));
    end endgenerate
    generate if (WAVEFORM_ENABLE) begin: live_wave
        wire [13:0] ui_signature = {main_menu,menu_page,zone,
            (PERFORMANCE_UI_ENABLE ? performance_mode : 1'b0),
            (PERFORMANCE_UI_ENABLE ? volume_percent : 8'd100)};
        wire [11:0] bounds;
        if(HIERARCHY_UI_ENABLE)begin: external_policy
            assign waveform_idle=external_waveform_view;
        end else begin: legacy_policy
        oled_idle_view #(.IDLE_CYCLES(WAVE_IDLE_CYCLES)) idle_control (
            .clk(clk),.rst_n(rst_n),.touch_active(ui_activity),.busy(busy),
            .error(error),.ui_signature(ui_signature),.waveform_view(waveform_idle)
        );
        end
        oled_wave_capture capture (
            .clk(clk),.rst_n(rst_n),.sample_valid(audio_sample_valid),.sample(audio_sample),
            .frame_snapshot(state==SNAPSHOT),.read_column(column),.read_bounds(bounds)
        );
        oled_wave_renderer wave_renderer (
            .clk(clk),.screen_page(screen_page),.column(column),.bounds(bounds),.data(wave_pixels)
        );
    end else begin: no_wave
        assign waveform_idle = 1'b0;
        assign wave_pixels = 8'd0;
    end endgenerate
    // 仍叫bus，保留原SDC中OLED输入双级同步器的精确层级名称。
    oled_i2c_stream #(.CLK_HZ(CLK_HZ),.I2C_HZ(I2C_HZ)) bus(
        .clk(clk),.resetn(rst_n),.cmd_valid(state==SEND),.cmd_ready(cmd_ready),
        .cmd_addr(ADDRESS),.cmd_control(control_byte),.cmd_length(stream_length),
        .data_valid(1'b1),.data_ready(stream_ready),.data(stream_data),
        .done(transaction_done),.error(transaction_error),.scl(scl),.sda(sda));
    function [7:0] init_byte;
        input [4:0] index;
        begin
            case(index)
                0:init_byte=8'hae;1:init_byte=8'hd5;2:init_byte=8'h80;
                3:init_byte=8'ha8;4:init_byte=8'h3f;5:init_byte=8'hd3;
                6:init_byte=0;7:init_byte=8'h40;8:init_byte=8'h8d;
                9:init_byte=8'h14;10:init_byte=8'h20;11:init_byte=8'h02;
                12:init_byte=8'ha1;13:init_byte=8'hc8;14:init_byte=8'hda;
                15:init_byte=8'h12;16:init_byte=8'h81;17:init_byte=8'h7f;
                18:init_byte=8'hd9;19:init_byte=8'hf1;20:init_byte=8'hdb;
                21:init_byte=8'h20;22:init_byte=8'ha4;23:init_byte=8'ha6;
                default:init_byte=8'haf;
            endcase
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            state<=POWER;timer<=0;init_index<=0;screen_page<=0;column<=0;
            page_command<=0;transfer_kind<=0;control_byte<=0;payload<=0;
            snap_main<=0;snap_page<=0;snap_zone<=0;snap_record<=0;
            snap_play<=0;snap_guide<=0;snap_busy<=0;snap_error<=0;snap_count<=0;
            bcd_start<=0;fault<=0;completed_frames<=0;
            snap_performance<=0;snap_volume<=100;
            snap_view<=0;snap_expression<=0;snap_control<=100;snap_negative<=0;snap_percent<=100;
            snap_sustain<=0;
            snap_wave<=0;
            count_done_seen<=0;volume_done_seen<=0;
        end else begin
            bcd_start<=0;
            // 成页流式发送时，数据握手才移动列地址；同步ROM/RAM有整字节时间准备下一列。
            if (WAVEFORM_ENABLE && transfer_kind==2 && state==WAIT_DONE && stream_ready && column!=127)
                column<=column+1'b1;
            case(state)
                POWER:if(timer+1>=POWER_WAIT_CYCLES)begin timer<=0;state<=INIT;end
                    else timer<=timer+1'b1;
                INIT:begin
                    transfer_kind<=0;control_byte<=0;payload<=init_byte(init_index);state<=SEND;
                end
                SNAPSHOT:begin
                    snap_main<=main_menu;snap_page<=menu_page;snap_zone<=zone;
                    snap_record<=recording;snap_play<=playing;snap_guide<=guide;
                    snap_busy<=busy;snap_error<=error;snap_count<=record_count;
                    snap_performance<=PERFORMANCE_UI_ENABLE && performance_mode;
                    snap_volume<=PERFORMANCE_UI_ENABLE ? volume_percent : 8'd100;
                    snap_view<=hierarchy_view;snap_expression<=expression_mode;
                    snap_control<=control_value;snap_negative<=control_negative;snap_percent<=control_percent;
                    snap_sustain<=SUSTAIN_UI_ENABLE && sustain_enabled;
                    snap_wave<=wave_requested;
                    count_done_seen<=0;volume_done_seen<=0;
                    bcd_start<=1;state<=BCD_WAIT;screen_page<=0;column<=0;page_command<=0;
                end
                BCD_WAIT:begin
                    // 事件数超9999会立即饱和，而音量需16拍转换；两路done不一定同拍。
                    // 分别记住完成状态，避免等待两个一次性脉冲重合而卡住显示。
                    if(bcd_done)count_done_seen<=1;
                    if(volume_bcd_done)volume_done_seen<=1;
                    if((bcd_done || count_done_seen) && (volume_bcd_done || volume_done_seen))state<=PAGE;
                end
                PAGE:begin
                    transfer_kind<=1;control_byte<=0;state<=SEND;
                    case(page_command)
                        0:payload<=8'hb0+screen_page;
                        1:payload<=COLUMN_OFFSET & 15;
                        default:payload<=8'h10+((COLUMN_OFFSET>>4)&15);
                    endcase
                end
                // 同步字模ROM预留一拍，DATA再取数，随后I2C握手锁存。
                RENDER_WAIT:state<=DATA;
                DATA:begin transfer_kind<=2;control_byte<=8'h40;payload<=pixels;state<=SEND;end
                SEND:if(cmd_ready)state<=WAIT_DONE;
                WAIT_DONE:if(transaction_done)begin
                    if(transaction_error!=0)begin fault<=1;timer<=0;state<=RETRY;end
                    else case(transfer_kind)
                        0:if(init_index==24)begin init_index<=0;state<=SNAPSHOT;end
                            else begin init_index<=init_index+1'b1;state<=INIT;end
                        1:if(page_command==2)state<=RENDER_WAIT;
                            else begin page_command<=page_command+1'b1;state<=PAGE;end
                        default:if (WAVEFORM_ENABLE && snap_wave && !wave_requested) begin
                            // 触摸/状态改变时，在当前页STOP之后恢复UI，不截断I2C事务。
                            state<=SNAPSHOT;
                        end else if(WAVEFORM_ENABLE || column==127)begin
                            column<=0;page_command<=0;
                            if(screen_page==7)begin
                                fault<=0;completed_frames<=completed_frames+1'b1;
                                timer<=0;state<=FRAME_WAIT;
                            end else begin screen_page<=screen_page+1'b1;state<=PAGE;end
                        end else begin column<=column+1'b1;state<=RENDER_WAIT;end
                    endcase
                end
                FRAME_WAIT:if(timer+1>=(snap_wave ? WAVE_FRAME_WAIT_CYCLES : FRAME_WAIT_CYCLES))begin timer<=0;state<=SNAPSHOT;end
                    else timer<=timer+1'b1;
                // 无屏/断线只影响显示，限速重试，不能拖住演奏或其他I2C。
                RETRY:if(timer+1>=POWER_WAIT_CYCLES)begin timer<=0;init_index<=0;state<=INIT;end
                    else timer<=timer+1'b1;
                default:state<=POWER;
            endcase
        end
    end
endmodule
