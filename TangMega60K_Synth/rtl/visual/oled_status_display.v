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
    parameter FONT_FILE="rtl/audio/rom/menu_font.hex"
) (
    input wire clk,rst_n,main_menu,
    input wire [1:0] menu_page,zone,
    input wire recording,playing,guide,busy,
    input wire [7:0] error,
    input wire [15:0] record_count,
    inout wire scl,sda,
    output reg fault,
    output reg [31:0] completed_frames
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
    reg bcd_start;
    wire bcd_done;
    wire [15:0] digits;
    wire [7:0] pixels;
    wire cmd_ready,transaction_done;
    wire [2:0] transaction_error;
    bin16_to_bcd decimal_count(.clk(clk),.rst_n(rst_n),.start(bcd_start),
        .value(snap_count),.digits(digits),.done(bcd_done));
    oled_menu_renderer #(.FONT_FILE(FONT_FILE)) renderer(
        .clk(clk),.screen_page(screen_page),.column(column),
        .main_menu(snap_main),.menu_page(snap_page),.zone(snap_zone),
        .recording(snap_record),.playing(snap_play),.guide(snap_guide),
        .busy(snap_busy),.error(snap_error),.record_digits(digits),.data(pixels));
    i2c_register_master #(.CLK_HZ(CLK_HZ),.I2C_HZ(I2C_HZ)) bus(
        .clk(clk),.resetn(rst_n),.cmd_valid(state==SEND),.cmd_ready(cmd_ready),
        .cmd_read(1'b0),.cmd_addr(ADDRESS),.cmd_reg(control_byte),
        .cmd_wdata(payload),.cmd_len(6'd1),.busy(),.done(transaction_done),
        .error(transaction_error),.rdata_valid(),.rdata(),.rindex(),.scl(scl),.sda(sda));
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
        end else begin
            bcd_start<=0;
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
                    bcd_start<=1;state<=BCD_WAIT;screen_page<=0;column<=0;page_command<=0;
                end
                BCD_WAIT:if(bcd_done)state<=PAGE;
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
                        default:if(column==127)begin
                            column<=0;page_command<=0;
                            if(screen_page==7)begin
                                fault<=0;completed_frames<=completed_frames+1'b1;
                                timer<=0;state<=FRAME_WAIT;
                            end else begin screen_page<=screen_page+1'b1;state<=PAGE;end
                        end else begin column<=column+1'b1;state<=RENDER_WAIT;end
                    endcase
                end
                FRAME_WAIT:if(timer+1>=FRAME_WAIT_CYCLES)begin timer<=0;state<=SNAPSHOT;end
                    else timer<=timer+1'b1;
                // 无屏/断线只影响显示，限速重试，不能拖住演奏或其他I2C。
                RETRY:if(timer+1>=POWER_WAIT_CYCLES)begin timer<=0;init_index<=0;state<=INIT;end
                    else timer<=timer+1'b1;
                default:state<=POWER;
            endcase
        end
    end
endmodule
