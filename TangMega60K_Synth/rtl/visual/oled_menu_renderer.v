// 由scripts/generate-menu-font.py生成；字模为GNU Unifont的OFL-1.1子集。
// 128x64：四行16像素文字。每帧输入由驱动快照，避免页面撕裂。
module oled_menu_renderer #(parameter FONT_FILE="rtl/audio/rom/menu_font.hex",
    parameter PERFORMANCE_UI_ENABLE=0) (
    input wire clk,input wire [2:0] screen_page,input wire [6:0] column,
    input wire main_menu,input wire [1:0] menu_page,zone,
    input wire recording,playing,guide,busy,input wire [7:0] error,
    input wire [15:0] record_digits,
    output wire [7:0] data,
    input wire performance_mode,input wire [11:0] volume_digits,
    input wire [7:0] volume_percent
);
    reg [55:0] text;
    wire [7:0] safe_percent=volume_percent>100 ? 8'd100 : volume_percent;
    // 120像素宽的横向刻度；比较乘积代替除法，边框4..123，内部6..121。
    wire [14:0] bar_scale={7'd0,safe_percent}*15'd116;
    wire [14:0] column_scale=column>=6 ? ({8'd0,column}-15'd6)*15'd100 : 15'd0;
    wire bar_fill=safe_percent!=0 && column>=6 && column<=121 && column_scale<bar_scale;
    wire [7:0] bar_byte=(column==4 || column==123) ? (screen_page[0]?8'h07:8'hfc) :
        (column>4 && column<123) ?
        (screen_page[0] ? (bar_fill?8'h07:8'h04) : (bar_fill?8'hfc:8'h04)) : 8'd0;
    always @* begin
        text=0;
        case(screen_page[2:1])
            0:if(PERFORMANCE_UI_ENABLE && performance_mode)text=56'h00000002444695;
              else if(main_menu)text=56'h00000142648890;else case(menu_page)
                0:text=56'h00000002444b15;1:text=56'h00000002444b95;
                2:text=56'h000000034a8c98;default:text=56'h00000005eb8e1b;endcase
            1:if(PERFORMANCE_UI_ENABLE && performance_mode)begin
                text=56'h00380810200695;
                text[27:21]=7'd1+{3'd0,volume_digits[11:8]};
                text[34:28]=7'd1+{3'd0,volume_digits[7:4]};
                text[41:35]=7'd1+{3'd0,volume_digits[3:0]};
              end else if(main_menu)text=56'h386cd182e54b15;else case(menu_page)
                0:text=56'h182d0a03c7cf1d;1:text=56'h048d2a404881a2;
                2:text=56'h58acd2a52a13a6;default:text=56'h62c17ae58acd2d;endcase
            2:begin
                if(error!=0)text=56'h00000000001c37;
                else if(busy)text=56'h000000000f5e3b;
                else if(recording)text=56'h000000000f8c98;
                else if(playing)text=56'h000000000f8d2d;
                else if(guide)text=56'h000000000f97ae;
                else text=56'h000000000fdd39;
                text[34:28]=7'd1+{3'd0,record_digits[15:12]};
                text[41:35]=7'd1+{3'd0,record_digits[11:8]};
                text[48:42]=7'd1+{3'd0,record_digits[7:4]};
                text[55:49]=7'd1+{3'd0,record_digits[3:0]};
            end
            default:if(PERFORMANCE_UI_ENABLE)begin
                if(performance_mode)text=56'h00488936ad19b2;
                else text=56'h0034aaa6a3d9b2;
              end else text=56'h00015366ad19b2;
        endcase
        if(PERFORMANCE_UI_ENABLE && !performance_mode && !main_menu && screen_page[2:1]==0)begin
            text[48:42]=7'd23;
            text[55:49]=7'd2+{5'd0,zone};
        end
    end
    wire [6:0] glyph=text[column[6:4]*7 +:7];
    reg [7:0] font[0:2047];
    reg [7:0] pixel_byte;
    reg inverse,bar_selected;
    reg [7:0] bar_registered;
    initial $readmemh(FONT_FILE,font);
    always @(posedge clk)begin
        pixel_byte<=font[{glyph,screen_page[0],column[3:0]}];
        inverse<=!(PERFORMANCE_UI_ENABLE && performance_mode) && screen_page[2:1]==1 && column[6:5]==zone;
        bar_selected<=PERFORMANCE_UI_ENABLE && performance_mode && screen_page[2:1]==2;
        bar_registered<=bar_byte;
    end
    assign data=bar_selected ? bar_registered : pixel_byte ^ {8{inverse}};
endmodule
