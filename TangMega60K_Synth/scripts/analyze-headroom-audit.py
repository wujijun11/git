"""分析4声部HDL诊断PCM；只量化增益切换，不把数字风险等同于现场噪声根因。"""
import argparse
import csv
import json
import math
import wave
from pathlib import Path

FULL_SCALE = 8388608


def decibels(value):
    return round(20 * math.log10(abs(value) / FULL_SCALE), 2) if value else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    with args.capture.open() as source:
        rows = [{key: int(value) for key, value in row.items()} for row in csv.DictReader(source)]
    transitions = []
    for previous, current in zip(rows, rows[1:]):
        if previous['boost'] != current['boost'] and previous['active'] and current['active']:
            # 固定余量参考仅有24位输出，缩放估计有量化误差，不是内部精确混音值。
            delta = current['left'] - current['fixed_left'] * (1 << previous['boost'])
            transitions.append({
                'frame': current['frame'], 'timeMs': round(current['frame'] / 48, 3),
                'oldActive': previous['active'], 'newActive': current['active'],
                'oldBoost': 1 << previous['boost'], 'newBoost': 1 << current['boost'],
                'actualAdjacentSampleStep': current['left'] - previous['left'],
                'estimatedHeadroomChange': delta, 'estimatedChangeDbFS': decibels(delta)
            })
    args.output.mkdir(parents=True, exist_ok=True)
    clipped = sum(row['left'] in (-8388608, 8388607) or row['right'] in (-8388608, 8388607) for row in rows)
    result = {
        'sampleRate': 48000, 'voiceCapacity': 4, 'capturedSamples': len(rows),
        'hardwareTested': False, 'pianoAlgorithmModified': False,
        'clippedFrames': clipped, 'headroomTransitions': transitions,
        'conclusion': '自动余量在声部数跨档时产生离散增益变化；本测试不能确认现场噼啪仅由此造成。',
        'sameKeyRetriggerFrame': 8500,
        'limits': ['没有模拟DAC、功放、电源和接线', '没有把波形自然斜率直接判成噪声',
                   '本次为4声部诊断，64声部菜单回归另有日志']
    }
    (args.output / 'headroom-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    with wave.open(str(args.output / 'headroom-hdl-simulation.wav'), 'wb') as output:
        output.setnchannels(2)
        output.setsampwidth(3)
        output.setframerate(48000)
        pcm = bytearray()
        for row in rows:
            for channel in ('left', 'right'):
                pcm.extend((row[channel] & 0xffffff).to_bytes(3, 'little'))
        output.writeframes(pcm)
    print(json.dumps(result, ensure_ascii=True))


if __name__ == '__main__':
    main()
