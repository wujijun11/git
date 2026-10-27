"""从既有HDL原始混音估算固定倍率峰值；不是新HDL仿真或限幅器实现。"""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path

PCM_MIN = -8388608
PCM_MAX = 8388607


def read_capture(path):
    """输入连续帧CSV；原始混音为64路16位求和，主增益为无符号Q1.11。"""
    with path.open(encoding='utf-8-sig', newline='') as source:
        rows = [{key: int(value) for key, value in row.items()} for row in csv.DictReader(source)]
    if not rows:
        raise ValueError('没有原始混音数据')
    for index, row in enumerate(rows):
        if row['frame'] != index + 1 or not 0 <= row['active'] <= 64:
            raise ValueError('帧编号或活跃声部数非法')
        if not 0 <= row['master_gain'] <= 4095:
            raise ValueError('主增益不在12位范围内')
        if any(not -2097152 <= row['raw_' + channel] <= 2097088 for channel in ('l', 'r')):
            raise ValueError('原始混音超出64路16位求和的理论边界')
    return rows


def unclipped_sample(raw_mix, fixed_gain, master_gain):
    """按现有主增益舍入和SHIFT=1估算；保留Python宽整数，不做饱和掩盖越界。"""
    return ((raw_mix * fixed_gain * master_gain + 1024) // 2048) * 2


def estimate(rows, fixed_gain):
    values = [unclipped_sample(row['raw_' + channel], fixed_gain, row['master_gain'])
              for row in rows for channel in ('l', 'r')]
    peak = max(abs(value) for value in values)
    return {
        'fixedGain': fixed_gain,
        'peakUnclipped': peak,
        'peakPercentOfFullScale': round(peak * 100 / 8388608, 3),
        'peakDbFS': round(20 * math.log10(peak / 8388608), 3) if peak else None,
        'clippedChannelSamplesWithoutLimiter': sum(value < PCM_MIN or value > PCM_MAX for value in values),
        'above80PercentChannelSamples': sum(abs(value) > 6710886 for value in values),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path, action='append', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    captures = []
    for path in args.capture:
        rows = read_capture(path)
        captures.append({
            'capture': path.as_posix(),
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest().upper(),
            'frames': len(rows),
            'durationSeconds': round(len(rows) / 48000, 6),
            'maxActiveVoices': max(row['active'] for row in rows),
            'maxMasterGain': max(row['master_gain'] for row in rows),
            'options': [estimate(rows, gain) for gain in (16, 32, 64)],
        })
    result = {
        'source': 'existing HDL raw-mix captures; offline gain arithmetic only',
        'captures': captures,
        'limits': [
            'short finite piano captures with specific notes, velocity and envelopes',
            'no proof for other timbres, effects, steady-state full load or coherent worst-case',
            'no limiter implemented, no new HDL simulation, no bitstream changed',
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=True))


if __name__ == '__main__':
    main()
