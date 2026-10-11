"""Combine existing SVG-rendered PNG previews with Chinese captions."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
ROOT=Path(__file__).parent
FONT=Path('C:/Windows/Fonts/msyh.ttc')
def font(size):return ImageFont.truetype(str(FONT),size)
top=Image.open(ROOT/'top_preview.png').convert('RGB')
bottom=Image.open(ROOT/'bottom_preview.png').convert('RGB')
w=max(top.width,bottom.width)
header=118;middle=96;footer=124
out=Image.new('RGB',(w,header+top.height+middle+bottom.height+footer),'#eef0f2')
d=ImageDraw.Draw(out)
d.text((24,12),'Touch25 R1｜25键电容触摸琴键 · C4–C6',font=font(32),fill='#1b2734')
d.text((24,62),'双层PCB 290 × 105 mm｜白键节距18 mm｜三组8 / 8 / 9路电极接口',font=font(24),fill='#3d4b5a')
out.paste(top,(0,header))
y=header+top.height
d.text((24,y+13),'底层走线：按正面透视方向显示，未左右镜像',font=font(27),fill='#1b2734')
d.text((24,y+55),'J1 / J2 / J3只接MPR121的ELE通道；不接FPGA GPIO或电源',font=font(23),fill='#3d4b5a')
out.paste(bottom,(0,y+middle))
y+=middle+bottom.height
d.text((24,y+14),'工程预览：色块提示覆阻焊的触摸电极，不能当实物照片或原生Gerber图。',font=font(23),fill='#3d4b5a')
d.text((24,y+53),'当前状态：原生DRC 141项0错误；实际Gerber独立检查163项全通过；尚未下单。',font=font(23),fill='#8a4914')
out.save(ROOT/'design_overview.png')
print(ROOT/'design_overview.png')
