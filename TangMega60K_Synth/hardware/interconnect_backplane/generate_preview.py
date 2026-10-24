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
    ("J_AHCT\\nDATA GND 5V_AUX", 670, 410, 210, 85, "#8a5b22"),
    ("J_LED_PWR\\nexternal regulated 5V", 930, 410, 210, 85, "#8a5b22"),
]
lines = [
    (320, 340, 360, 290, "#c43b4a"), (320, 360, 360, 290, "#c43b4a"),
    (320, 380, 670, 290, "#48ad70"), (320, 400, 670, 290, "#48ad70"),
    (320, 420, 360, 455, "#4d8fd6"), (320, 440, 360, 455, "#4d8fd6"),
    (320, 460, 360, 130, "#b38ddb"), (320, 480, 360, 130, "#b38ddb"),
    (320, 500, 670, 452, "#e0a24a"), (320, 520, 670, 452, "#e0a24a"),
]
svg = [
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
    '<rect width="100%" height="100%" fill="#10151c"/>',
    '<text x="42" y="42" fill="#fff" font-size="26" font-family="Arial">Tang Mega 60K 外设转接底板 R0</text>',
    '<text x="42" y="70" fill="#b9c7d8" font-size="15" font-family="Arial">被动分线：J13直插、MPR三路独立、C3串口、AHCT/LED 5V隔离</text>',
]
for x1, y1, x2, y2, color in lines:
    svg.append(f'<path d="M{x1} {y1} C{(x1+x2)//2} {y1}, {(x1+x2)//2} {y2}, {x2} {y2}" stroke="{color}" stroke-width="4" fill="none" opacity=".9"/>')
for label, x, y, w, h, color in parts:
    svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{color}" stroke="#d9e5f2" stroke-width="2"/>')
    for i, line in enumerate(label.split("\\n")):
        svg.append(f'<text x="{x+14}" y="{y+30+i*22}" fill="#fff" font-size="16" font-family="Arial">{escape(line)}</text>')
svg += [
    '<text x="60" y="690" fill="#f2c14e" font-size="16" font-family="Arial">J13-11 保留 NC；5V_AUX 只进入 AHCT/灯板侧；所有接口先断电核对</text>',
    '</svg>',
]
OUT.write_text("\n".join(svg), encoding="utf-8")
print(OUT)
