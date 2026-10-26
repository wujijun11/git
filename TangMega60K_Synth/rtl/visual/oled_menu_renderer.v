// 由scripts/generate-menu-font.py生成；字模为GNU Unifont的OFL-1.1子集。
// 128x64：四行16像素文字。每帧输入由驱动快照，避免页面撕裂。
module oled_menu_renderer #(parameter FONT_FILE="rtl/audio/rom/menu_font.hex") (
    input wire clk,input wire [2:0] screen_page,input wire [6:0] column,
    input wire main_menu,input wire [1:0] menu_page,zone,
    input wire recording,playing,guide,busy,input wire [7:0] error,
    input wire [15:0] record_digits,
    output wire [7:0] data
);
    reg [55:0] text;
    always @* begin
        text=0;
        case(screen_page[2:1])
            0:if(main_menu)text=56'h00000142648890;else case(menu_page)
                0:text=56'h00000002444b15;1:text=56'h00000002444b95;
                2:text=56'h000000034a8c98;default:text=56'h00000005eb8e1b;endcase
            1:if(main_menu)text=56'h386cd182e54b15;else case(menu_page)
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
            default:text=56'h00015366ad19b2;
        endcase
    end
    wire [6:0] glyph=text[column[6:4]*7 +:7];
    reg [7:0] font[0:2047];
    reg [7:0] pixel_byte;
    reg inverse;
    initial $readmemh(FONT_FILE,font);
    always @(posedge clk)begin
        pixel_byte<=font[{glyph,screen_page[0],column[3:0]}];
        inverse<=screen_page[2:1]==1 && column[6:5]==zone;
    end
    assign data=pixel_byte ^ {8{inverse}};
endmodule
