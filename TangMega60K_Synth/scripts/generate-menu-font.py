"""从GNU Unifont提取菜单需要的16x16字模，生成OLED页式ROM和显示模块。

仅离线生成字体数据，不生成音频。字模沿用OFL-1.1授权，原始字体不放进RTL。
"""
import argparse
import gzip
import hashlib
import json
import tarfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
# 原来未使用的冒号/加减号三槽改为量/%/右；其余编号不变，仍为64字/2048字节。
GLYPHS = " 0123456789FM量%右总模式选择音色区录制放曲谱钢琴风正弦低高标准开始结束回停止播指引关闭长按左端返回错误事件请等待中数"


def extract_glyphs(path, characters):
    wanted = {ord(char) for char in characters}
    glyphs = {}
    with gzip.open(path, "rt", encoding="ascii") as source:
        for line in source:
            code, bitmap = line.strip().split(":", 1)
            if int(code, 16) not in wanted:
                continue
            width = len(bitmap) // 4
            if width not in (8, 16):
                raise ValueError(f"不支持的字模宽度 {width}")
            stride = width // 4
            rows = [int(bitmap[row * stride:(row + 1) * stride], 16)
                    for row in range(16)]
            if width == 8:
                rows = [value << 4 for value in rows]
            columns = [sum(((rows[half * 8 + bit] >> (15 - x)) & 1) << bit
                           for bit in range(8)) for half in range(2) for x in range(16)]
            glyphs[chr(int(code, 16))] = columns
    missing = set(characters) - glyphs.keys()
    if missing:
        raise ValueError(f"缺少字符：{missing}")
    return glyphs


def generate_renderer(ids, depth):
    def text(value):
        if len(value) > 8:
            raise ValueError(value)
        packed = sum(ids[char] << (7 * index) for index, char in enumerate(value.ljust(8)))
        return f"56'h{packed:014x}"
    titles = [text(s) for s in ("音色模式", "音区模式", "录制回放", "曲谱指引")]
    items = [text(s) for s in ("钢琴风琴正弦FM", "低2低1标准高1", "开始结束回放停止", "播放停止指引关闭")]
    return f'''// 由scripts/generate-menu-font.py生成；字模为GNU Unifont的OFL-1.1子集。
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
    wire [14:0] bar_scale={{7'd0,safe_percent}}*15'd116;
    wire [14:0] column_scale=column>=6 ? ({{8'd0,column}}-15'd6)*15'd100 : 15'd0;
    wire bar_fill=safe_percent!=0 && column>=6 && column<=121 && column_scale<bar_scale;
    wire [7:0] bar_byte=(column==4 || column==123) ? (screen_page[0]?8'h07:8'hfc) :
        (column>4 && column<123) ?
        (screen_page[0] ? (bar_fill?8'h07:8'h04) : (bar_fill?8'hfc:8'h04)) : 8'd0;
    always @* begin
        text=0;
        case(screen_page[2:1])
            0:if(PERFORMANCE_UI_ENABLE && performance_mode)text={text('音量模式')};
              else if(main_menu)text={text('总模式选择')};else case(menu_page)
                0:text={titles[0]};1:text={titles[1]};
                2:text={titles[2]};default:text={titles[3]};endcase
            1:if(PERFORMANCE_UI_ENABLE && performance_mode)begin
                text={text('音量 000%')};
                text[27:21]=7'd{ids['0']}+{{3'd0,volume_digits[11:8]}};
                text[34:28]=7'd{ids['0']}+{{3'd0,volume_digits[7:4]}};
                text[41:35]=7'd{ids['0']}+{{3'd0,volume_digits[3:0]}};
              end else if(main_menu)text={text('音色音区录放曲谱')};else case(menu_page)
                0:text={items[0]};1:text={items[1]};
                2:text={items[2]};default:text={items[3]};endcase
            2:begin
                if(error!=0)text={text('错误')};
                else if(busy)text={text('请等待')};
                else if(recording)text={text('录制中')};
                else if(playing)text={text('播放中')};
                else if(guide)text={text('指引中')};
                else text={text('事件数')};
                text[34:28]=7'd{ids['0']}+{{3'd0,record_digits[15:12]}};
                text[41:35]=7'd{ids['0']}+{{3'd0,record_digits[11:8]}};
                text[48:42]=7'd{ids['0']}+{{3'd0,record_digits[7:4]}};
                text[55:49]=7'd{ids['0']}+{{3'd0,record_digits[3:0]}};
            end
            default:if(PERFORMANCE_UI_ENABLE)begin
                if(performance_mode)text={text('长按左端选模式')};
                else text={text('长按右端回音量')};
              end else text={text('长按左端返回')};
        endcase
        if(PERFORMANCE_UI_ENABLE && !performance_mode && !main_menu && screen_page[2:1]==0)begin
            text[48:42]=7'd{ids['区']};
            text[55:49]=7'd{ids['1']}+{{5'd0,zone}};
        end
    end
    wire [6:0] glyph=text[column[6:4]*7 +:7];
    reg [7:0] font[0:{depth-1}];
    reg [7:0] pixel_byte;
    reg inverse,bar_selected;
    reg [7:0] bar_registered;
    initial $readmemh(FONT_FILE,font);
    always @(posedge clk)begin
        pixel_byte<=font[{{glyph,screen_page[0],column[3:0]}}];
        inverse<=!(PERFORMANCE_UI_ENABLE && performance_mode) && screen_page[2:1]==1 && column[6:5]==zone;
        bar_selected<=PERFORMANCE_UI_ENABLE && performance_mode && screen_page[2:1]==2;
        bar_registered<=bar_byte;
    end
    assign data=bar_selected ? bar_registered : pixel_byte ^ {{8{{inverse}}}};
endmodule
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("font_gzip", type=Path)
    license_source = parser.add_mutually_exclusive_group(required=True)
    license_source.add_argument("--source-tar", type=Path)
    license_source.add_argument("--reuse-license", action="store_true",
                                help="只在原始字体哈希与既有授权清单一致时复用本地OFL文件")
    args = parser.parse_args()
    licenses = PROJECT / "licenses/menu-font"
    if args.reuse_license:
        previous = json.loads((licenses / "manifest.json").read_text(encoding="utf-8"))
        if previous["sourceSha256"] != hashlib.sha256(args.font_gzip.read_bytes()).hexdigest():
            raise ValueError("字体原文件与原授权清单不一致，不能复用授权记录")
        if not all((licenses / name).is_file() for name in ("COPYING", "OFL-1.1.txt")):
            raise ValueError("本地字体授权文件不完整")
    chars = list(dict.fromkeys(GLYPHS))
    if len(chars) > 128:
        raise ValueError("字符编号超过7位")
    ids = {char: index for index, char in enumerate(chars)}
    glyphs = extract_glyphs(args.font_gzip, chars)
    depth = (1 << (len(chars) - 1).bit_length()) * 32
    data = [byte for char in chars for byte in glyphs[char]]
    data += [0] * (depth - len(data))
    rom = PROJECT / "rtl/audio/rom/menu_font.hex"
    rom.write_text("".join(f"{byte:02X}\n" for byte in data), encoding="ascii")
    (PROJECT / "rtl/visual/oled_menu_renderer.v").write_text(
        generate_renderer(ids, depth), encoding="utf-8")
    licenses.mkdir(parents=True, exist_ok=True)
    if args.source_tar:
        with tarfile.open(args.source_tar, "r:gz") as archive:
            for name in ("COPYING", "OFL-1.1.txt"):
                source = archive.extractfile(f"unifont-16.0.04/{name}")
                (licenses / name).write_bytes(source.read())
    manifest = {"font": "MenuGlyphSubset", "source": "GNU Unifont 16.0.04",
                "url": "https://unifoundry.com/pub/unifont/unifont-16.0.04/font-builds/unifont-16.0.04.hex.gz",
                "sourceSha256": hashlib.sha256(args.font_gzip.read_bytes()).hexdigest(),
                "license": "OFL-1.1", "glyphs": ids, "romBytes": depth}
    (licenses / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"glyphCount": len(chars), "romBytes": depth, "rom": str(rom)}))


if __name__ == "__main__":
    main()
