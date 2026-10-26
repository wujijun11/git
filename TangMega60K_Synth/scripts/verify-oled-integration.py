"""核对完整板级仿真从OLED引脚解码的首帧，并以纯Python导出预览PNG。"""
import argparse
import hashlib
import json
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def hex_bytes(path):
    result = []
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        line = line.split("//", 1)[0].strip()
        if line and not line.startswith("@"):
            result.extend(int(token, 16) for token in line.split())
    return result


def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)


def save_preview(path, values, scale=6):
    # 每页8行，每个字节为一列；颜色只模拟常见黄蓝分区，实屏以型号为准。
    width, height = 128 * scale, 64 * scale
    pixels = bytearray()
    for y in range(height):
        pixels.append(0)
        for x in range(width):
            sx, sy = x // scale, y // scale
            lit = values[(sy // 8) * 128 + sx] & (1 << (sy % 8))
            pixels.extend(((255, 222, 64) if sy < 16 else (100, 202, 255)) if lit else (8, 12, 16))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
                     png_chunk(b"IDAT", zlib.compress(bytes(pixels))) + png_chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    font = hex_bytes(ROOT / "rtl/audio/rom/menu_font.hex")
    glyphs = json.loads((ROOT / "licenses/menu-font/manifest.json").read_text(encoding="utf-8"))["glyphs"]
    lines = ["音色模式".ljust(8), "钢琴风琴正弦FM", "事件数 0000", "长按左端返回".ljust(8)]
    expected = []
    for page in range(8):
        for column in range(128):
            char = lines[page // 2][column // 16]
            byte = font[glyphs[char] * 32 + (page % 2) * 16 + column % 16]
            expected.append(byte ^ (255 if page // 2 == 1 and column // 32 == 0 else 0))
    captured = hex_bytes(args.capture)
    if captured != expected:
        raise ValueError(f"OLED板级字节不匹配：实际{len(captured)}，不同字节{sum(a != b for a, b in zip(captured, expected))}")
    args.output.mkdir(parents=True, exist_ok=True)
    save_preview(args.output / "oled-board-preview.png", captured)
    report = {"passed": True, "bytesCompared": 1024, "source": "decoded top-level oled_scl/oled_sda",
              "textRows": lines, "invertedZone": 0, "captureSha256": hashlib.sha256(args.capture.read_bytes()).hexdigest(),
              "physicalDisplayTested": False, "colorNote": "Preview colors are illustrative; physical yellow/blue partition not verified"}
    (args.output / "frame-result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print("OLED BOARD FRAME PASS: 1024 independently reconstructed bytes and PNG preview")


if __name__ == "__main__":
    main()
