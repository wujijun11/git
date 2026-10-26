"""独立核对ModelSim捕获的整屏I2C字节，并导出放大预览。"""
import argparse
import json
from pathlib import Path
from PIL import Image

PROJECT = Path(__file__).resolve().parents[1]


def read_hex(path):
    return [int(line.split('//')[0].strip(), 16) for line in path.read_text().splitlines()
            if line.split('//')[0].strip() and not line.strip().startswith('@')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    font = read_hex(PROJECT / 'rtl/audio/rom/menu_font.hex')
    ids = json.loads((PROJECT / 'licenses/menu-font/manifest.json').read_text(encoding='utf-8'))['glyphs']
    rows = ['总模式选择'.ljust(8), '音色音区录放曲谱', '事件数 1234', '长按左端返回'.ljust(8)]
    expected = []
    for page in range(8):
        for column in range(128):
            char = rows[page // 2][column // 16]
            byte = font[ids[char] * 32 + (page % 2) * 16 + column % 16]
            expected.append(byte ^ (255 if page // 2 == 1 and column // 32 == 1 else 0))
    captured = read_hex(args.capture)
    if captured != expected:
        raise AssertionError(f'整屏字节与独立字模参考不符，长度{len(captured)}，差异'
                             f'{sum(a != b for a, b in zip(captured, expected))}')
    args.output.mkdir(parents=True, exist_ok=True)
    image = Image.new('RGB', (128, 64), (8, 12, 16))
    for page in range(8):
        for x in range(128):
            for bit in range(8):
                if captured[page * 128 + x] & (1 << bit):
                    y = page * 8 + bit
                    image.putpixel((x, y), (255, 222, 64) if y < 16 else (100, 202, 255))
    image.resize((768, 384), Image.Resampling.NEAREST).save(args.output / 'oled-menu-preview.png')
    (args.output / 'oled-frame-result.json').write_text(json.dumps({
        'pass': True, 'bytesCompared': 1024, 'snapshotChangedDuringTransfer': True,
        'hardwareTested': False, 'preview': '模拟黄蓝固定分区；实物亮度/分区待确认'
    }, ensure_ascii=False, indent=2), encoding='utf-8')
    print('OLED FRAME BYTE COMPARISON PASS (1024 bytes)')


if __name__ == '__main__':
    main()
