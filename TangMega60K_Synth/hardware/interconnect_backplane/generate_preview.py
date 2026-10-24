from pathlib import Path
from xml.sax.saxutils import escape

OUT = Path(__file__).with_name("layout_preview.svg")
W, H = 1200, 760
parts = [
    ("J_FPGA_J13", 60, 285, 260, 150, "#18283f"),
    ("J_PWR_3V3\\n(J9 input)", 60, 90, 190, 80, "#214a42"),
    ("J_C3\\nTX7/RX6/GND", 360, 90, 210, 80, "#3d2a56"),
    ("J_MPR1\\n3V3 GND ADD SCL SDA IRQ", 360, 245, 270, 100, "#8b2938"),
    ("J_MPR2\\n3V3 GND ADD SCL SDA IRQ", 670, 245, 270, 100, "#2f7b50"),
    ("J_MPR3\\n3V3 GND ADD SCL SDA IRQ", 360, 410, 270, 100, "#2d5f98"),
    ("J_AHCT -> AHCT J1\\nDATA GND (2P)", 670, 410, 230, 85, "#8a5b22"),
    ("J_AHCT_PWR -> J3\\n+5V_AUX GND (2P)", 670, 535, 230, 85, "#8a5b22"),
    ("J_LED_PWR\\nexternal regulated 5V", 930, 410, 210, 85, "#8a5b22"),
]
lines = [
    (320, 310, 360, 290, "#c43b4a"),
    (320, 340, 670, 290, "#48ad70"),
    (320, 370, 360, 455, "#4d8fd6"),
    (320, 400, 360, 130, "#b38ddb"),
    (320, 420, 670, 452, "#e0a24a"),
]
svg = [
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
    '<rect width="100%" height="100%" fill="#10151c"/>',
    '<text x="42" y="42" fill="#fff" font-size="26" font-family="Arial">Tang Mega 60K 外设转接底板 R0.1</text>',
    '<text x="42" y="70" fill="#b9c7d8" font-size="15" font-family="Arial">连接关系示意，非PCB布局；MPR针序/模块安装方式待核实；AHCT信号和电源分开</text>',
]
for x1, y1, x2, y2, color in lines:
    svg.append(f'<path d="M{x1} {y1} C{(x1+x2)//2} {y1}, {(x1+x2)//2} {y2}, {x2} {y2}" stroke="{color}" stroke-width="4" fill="none" opacity=".9"/>')
for label, x, y, w, h, color in parts:
    svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{color}" stroke="#d9e5f2" stroke-width="2"/>')
    for i, line in enumerate(label.split("\\n")):
        svg.append(f'<text x="{x+14}" y="{y+30+i*22}" fill="#fff" font-size="16" font-family="Arial">{escape(line)}</text>')
svg += [
    '<path d="M1040 495 V577 H900" stroke="#e0a24a" stroke-width="4" fill="none"/>',
    '<text x="60" y="660" fill="#b9c7d8" font-size="16" font-family="Arial">MPR/C3框内顺序是底板侧线束定义，不能据此把模块直接整排插入。</text>',
    '<text x="60" y="690" fill="#f2c14e" font-size="16" font-family="Arial">J13-11及15~40 保留 NC；5V_AUX 只进入 AHCT电源端；GND共地；不可据此下单</text>',
    '</svg>',
]
OUT.write_text("\n".join(svg) + "\n", encoding="utf-8", newline="\n")
print(OUT)
