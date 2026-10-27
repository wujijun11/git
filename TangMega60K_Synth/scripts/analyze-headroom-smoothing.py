"""核对同命令HDL PCM的余量变化并导出原音量24位WAV；不推断实物噪声根因。

使用未缩放的混音与提交参数独立核对全部样本。将增益变化对当前样本的
影响与波形自然斜率分开，避免把正常高频波形的一阶差分误当成噪声。
"""
import argparse
import csv
import hashlib
import json
import math
import wave
from pathlib import Path

SAMPLE_RATE = 48000
MIX_MIN, MIX_MAX = -2097152, 2097088
PCM_MIN, PCM_MAX = -8388608, 8388607


def bound(value, low, high):
    return min(high, max(low, value))


def output_sample(raw_mix, gain_q10, master, guarded):
    mixed = (raw_mix * gain_q10 + 512) // 1024
    if guarded:
        mixed = bound(mixed, MIX_MIN, MIX_MAX)
    return bound(((mixed * master + 1024) // 2048) * 2, PCM_MIN, PCM_MAX)


def dbfs(value):
    return None if value == 0 else round(20 * math.log10(abs(value) / 8388608), 3)


def analyze(rows):
    if not rows:
        raise ValueError('没有PCM数据')
    transitions = []
    steady = guards = clipped_old = clipped_new = 0
    max_delta_old = max_delta_new = 0
    for index, row in enumerate(rows):
        if row['frame'] != index + 1 or not 0 <= row['active'] <= 64:
            raise ValueError('样本编号不连续或声部数非法')
        target = 1024 * (1 << row['shift'])
        if not 1024 <= row['gain_q10'] <= 65536:
            raise ValueError('平滑增益超出1..64倍设计范围')
        expected_guard = any(not MIX_MIN <= (row['raw_' + channel] * row['gain_q10'] + 512) // 1024 <= MIX_MAX
                             for channel in ('l', 'r'))
        if bool(row['guard']) != expected_guard:
            raise ValueError('峰值保护标志与独立宽位公式不匹配')
        for channel in ('l', 'r'):
            expected_old = output_sample(row['raw_' + channel], target, row['master_gain'], False)
            expected_new = output_sample(row['raw_' + channel], row['gain_q10'], row['master_gain'], True)
            if row['old_' + channel] != expected_old or row['new_' + channel] != expected_new:
                raise ValueError(f'独立整数公式不匹配 frame={row["frame"]} channel={channel}')
        if row['gain_q10'] == target and not row['guard']:
            if (row['old_l'], row['old_r']) != (row['new_l'], row['new_r']):
                raise ValueError('相同稳态标度的PCM不一致')
            steady += 1
        guards += bool(row['guard'])
        clipped_old += row['old_l'] in (PCM_MIN, PCM_MAX) or row['old_r'] in (PCM_MIN, PCM_MAX)
        clipped_new += row['new_l'] in (PCM_MIN, PCM_MAX) or row['new_r'] in (PCM_MIN, PCM_MAX)
        if not index:
            continue
        previous = rows[index - 1]
        max_delta_old = max(max_delta_old, abs(row['old_l'] - previous['old_l']), abs(row['old_r'] - previous['old_r']))
        max_delta_new = max(max_delta_new, abs(row['new_l'] - previous['new_l']), abs(row['new_r'] - previous['new_r']))
        if row['shift'] != previous['shift'] and row['active'] and previous['active']:
            old_effect = new_effect = 0
            for channel in ('l', 'r'):
                raw = row['raw_' + channel]
                old_reference = output_sample(raw, 1024 * (1 << previous['shift']), row['master_gain'], False)
                new_reference = output_sample(raw, previous['gain_q10'], row['master_gain'], True)
                old_effect = max(old_effect, abs(row['old_' + channel] - old_reference))
                new_effect = max(new_effect, abs(row['new_' + channel] - new_reference))
            settled = next((future['frame'] - row['frame'] + 1 for future in rows[index:index + 64]
                            if future['gain_q10'] == target), None)
            transitions.append({
                'frame': row['frame'], 'timeMs': round((row['frame'] - 1) / 48, 3),
                'voicesBefore': previous['active'], 'voicesAfter': row['active'],
                'factorBefore': 1 << previous['shift'], 'factorAfter': 1 << row['shift'],
                'oldGainChangeContribution': old_effect, 'newGainChangeContribution': new_effect,
                'oldContributionDbFS': dbfs(old_effect), 'newContributionDbFS': dbfs(new_effect),
                'reductionPercent': round(100 * (1 - new_effect / old_effect), 3) if old_effect else None,
                'framesToTargetObserved': settled,
                'note': '当前同一个原始混音值上隔离增益变化贡献；不是声学噪声测量',
            })
    if clipped_new:
        raise ValueError(f'平滑输出出现24位端点削波：{clipped_new}帧')
    return {
        'passed': True, 'sampleRateHz': SAMPLE_RATE, 'samples': len(rows), 'hardwareTested': False,
        'allSamplesCheckedAgainstRawMix': True, 'steadyBitExactSamples': steady,
        'peakGuardFrames': guards, 'clippedOldFrames': clipped_old, 'clippedNewFrames': clipped_new,
        'peakOld': max(abs(row['old_' + channel]) for row in rows for channel in ('l', 'r')),
        'peakNew': max(abs(row['new_' + channel]) for row in rows for channel in ('l', 'r')),
        'maximumAdjacentStepOld': max_delta_old, 'maximumAdjacentStepNew': max_delta_new,
        'transitions': transitions,
        'limits': ['没有DAC/功放/接线/电源模型', '整体样本差分不是噼啪检测器',
                   '只检查本次具体激励；瞬态峰值保护可能引入非线性', '平滑时间按生成帧数，48kHz连续输出时最多1.333ms'],
    }


def write_wav(path, samples):
    with wave.open(str(path), 'wb') as output:
        output.setnchannels(2)
        output.setsampwidth(3)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(b''.join((sample & 0xffffff).to_bytes(3, 'little') for frame in samples for sample in frame))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    with args.capture.open(encoding='utf-8-sig', newline='') as source:
        rows = [{key: int(value) for key, value in row.items()} for row in csv.DictReader(source)]
    result = analyze(rows)
    args.output.mkdir(parents=True, exist_ok=True)
    result['captureSha256'] = hashlib.sha256(args.capture.read_bytes()).hexdigest().upper()
    (args.output / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    old = [(row['old_l'], row['old_r']) for row in rows]
    new = [(row['new_l'], row['new_r']) for row in rows]
    write_wav(args.output / 'original-hdl.wav', old)
    write_wav(args.output / 'smoothed-hdl.wav', new)
    write_wav(args.output / 'original-then-smoothed.wav', old + [(0, 0)] * 12000 + new)
    print(json.dumps(result, ensure_ascii=True))


if __name__ == '__main__':
    main()
