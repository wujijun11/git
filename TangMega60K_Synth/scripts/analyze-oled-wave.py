"""独立核对外部I2S解码PCM与OLED总线捕获像素，生成真实仿真帧预览。"""
import argparse
import csv
import hashlib
import json
import struct
import zlib
from pathlib import Path


def read_frame(path):
    values = []
    for line in path.read_text(encoding='ascii').splitlines():
        content = line.split('//', 1)[0].strip()
        if not content or content.startswith('@'):
            continue
        values.extend(int(token, 16) for token in content.split())
    if len(values) != 1024 or any(value > 255 for value in values):
        raise ValueError('应为128x64页格式的1024字节真实捕获')
    return values


def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


def render(frame, path):
    """放大真实页数据；黄/蓝仅模拟双色屏分区，不声称是实物照片。"""
    scale = 6
    lines = []
    for y in range(64 * scale):
        line = bytearray(b'\x00')
        for x in range(128 * scale):
            lit = frame[(y // scale // 8) * 128 + x // scale] >> (y // scale % 8) & 1
            line.extend(((255, 220, 70) if y // scale < 16 else (92, 201, 255)) if lit else (8, 12, 16))
        lines.append(line)
    image = b'\x89PNG\r\n\x1a\n'
    image += png_chunk(b'IHDR', struct.pack('>IIBBBBB', 128 * scale, 64 * scale, 8, 2, 0, 0, 0))
    image += png_chunk(b'IDAT', zlib.compress(b''.join(lines), 9)) + png_chunk(b'IEND', b'')
    path.write_bytes(image)


def analyze(frame, rows):
    if len(rows) != 512 or [row['frame'] for row in rows] != list(range(512)):
        raise ValueError('需要512个连续外部I2S左声道样本')
    expected = list(frame)
    visual_saturated = 0
    for column in range(128):
        first = 0 if column == 0 else column * 4 - 1
        samples = [row['left'] for row in rows[first:column * 4 + 4]]
        scaled = [sample // 32768 for sample in samples]
        visual_saturated += any(value > 22 or value < -22 for value in scaled)
        heights = [24 - min(22, max(-22, value)) for value in scaled]
        for page in range(2, 8):
            expected[page * 128 + column] = sum(
                1 << bit for bit in range(8)
                if min(heights) <= (page - 2) * 8 + bit <= max(heights)
                or ((page - 2) * 8 + bit == 24 and column % 8 == 0)
            )
    if expected != frame:
        raise ValueError('实际OLED波形像素与独立I2S样本参考不一致')
    return {
        'passed': True,
        'pixelsComparedBytes': 768,
        'headerCompared': False,
        'i2sSamples': 512,
        'sampleRateHz': 48000,
        'windowMs': 512 / 48,
        'visualSaturatedColumns': visual_saturated,
        'source': 'external I2S pin decode and external OLED I2C pin capture in simulation',
        'hardwareTested': False,
        'note': 'display scaling saturation is separate from audio clipping; audio path is unchanged',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture_directory', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    frame_path = args.capture_directory / 'oled_real_audio_frame.hex'
    pcm_path = args.capture_directory / 'oled_scope_pcm.csv'
    frame = read_frame(frame_path)
    with pcm_path.open(encoding='utf-8-sig', newline='') as source:
        rows = [{key: int(value) for key, value in row.items()} for row in csv.DictReader(source)]
    result = analyze(frame, rows)
    result['frameSha256'] = hashlib.sha256(frame_path.read_bytes()).hexdigest().upper()
    result['pcmSha256'] = hashlib.sha256(pcm_path.read_bytes()).hexdigest().upper()
    args.output.mkdir(parents=True, exist_ok=True)
    render(frame, args.output / 'OLED真实音频波形_仿真像素.png')
    for name in ('oled_idle_wave_frame', 'oled_awake_menu_frame'):
        path = args.capture_directory / (name + '.hex')
        if path.exists():
            render(read_frame(path), args.output / (name + '.png'))
    (args.output / 'analysis.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=True))


if __name__ == '__main__':
    main()
