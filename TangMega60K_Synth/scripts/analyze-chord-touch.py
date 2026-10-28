"""分析实际RTL导出的PCM和数字延迟；不将仿真结果冒充DAC/喇叭实测。"""
import argparse
import csv
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import wave

SAMPLE_RATE = 48000


def read_csv(path):
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return [{key: int(value) for key, value in row.items()} for row in csv.DictReader(stream)]


def component_amplitude(rows, column):
    """同时拟合440Hz、E5及直流，避免短窗中另一个音泄漏而误判原音的大小。"""
    frequencies = (440.0, 440.0 * 2 ** (7 / 12))
    size = 5
    matrix = [[0.0] * (size + 1) for _ in range(size)]
    for index, row in enumerate(rows):
        basis = [1.0]
        for frequency in frequencies:
            phase = 2 * math.pi * frequency * index / SAMPLE_RATE
            basis.extend((math.cos(phase), math.sin(phase)))
        for a in range(size):
            for b in range(size):
                matrix[a][b] += basis[a] * basis[b]
            matrix[a][size] += basis[a] * row[column]
    # 带主元高斯消元。这里只处理独立正弦参考，不用于概括钢琴主观响度。
    for col in range(size):
        pivot = max(range(col, size), key=lambda row: abs(matrix[row][col]))
        matrix[col], matrix[pivot] = matrix[pivot], matrix[col]
        divisor = matrix[col][col]
        if abs(divisor) < 1e-12:
            raise ValueError("Singular frequency reference")
        matrix[col] = [value / divisor for value in matrix[col]]
        for row in range(size):
            if row != col:
                scale = matrix[row][col]
                matrix[row] = [a - scale * b for a, b in zip(matrix[row], matrix[col])]
    coefficients = [row[-1] for row in matrix]
    return math.hypot(coefficients[1], coefficients[2])


def write_audio(rows, path, prefix):
    """48kHz/24bit双声道原标度，不对新旧音频分别归一化。"""
    payload = bytearray()
    for row in rows:
        for channel in ("left", "right"):
            value = row[f"{prefix}_{channel}"]
            if not -(1 << 23) <= value < (1 << 23):
                raise ValueError("PCM out of signed 24-bit range")
            payload.extend(value.to_bytes(3, "little", signed=True))
    with wave.open(str(path), "wb") as target:
        target.setnchannels(2)
        target.setsampwidth(3)
        target.setframerate(SAMPLE_RATE)
        target.writeframes(payload)


def analyze_audio(source, output):
    sine = read_csv(source / "chord_sine_compare.csv")
    piano = read_csv(source / "chord_piano_compare.csv")
    stages = {number: [row for row in sine if row["stage"] == number] for number in (1, 3)}
    amplitudes = {
        variant: [component_amplitude(stages[number], variant + "_left") for number in (1, 3)]
        for variant in ("old", "new")
    }
    ratios = {name: values[1] / values[0] for name, values in amplitudes.items()}
    if not 0.49 < ratios["old"] < 0.51 or not 0.99 < ratios["new"] < 1.01:
        raise ValueError(f"Held A4 gain regression: {ratios}")
    for rows in (sine, piano):
        if max(row["voices"] for row in rows) not in (4, 64):
            raise ValueError("Missing full voice coverage")
        for row in rows:
            if max(abs(row["new_left"]), abs(row["new_right"])) > 4194303:
                raise ValueError("Peak ceiling violated")
    if max(row["voices"] for row in sine) != 64:
        raise ValueError("64 voice evidence missing")
    demo = [row for row in piano if row["stage"] in (1, 2, 3)]
    for variant in ("old", "new"):
        write_audio(demo, output / ("piano_" + variant + ".wav"), variant)
    solo = [row for row in sine if row["stage"] == 1]
    if any(row["new_left"] != row["old_left"] or row["new_right"] != row["old_right"] for row in solo):
        raise ValueError("Neutral single-note PCM scale changed")
    return {"passed": True, "heldA4ComponentRatios": ratios, "componentAmplitudes": amplitudes,
            "singleNoteBitExact": True, "voiceCountVerified": 64, "newPeakCeiling": 4194303,
            "dryFullScaleRailSamples": sum(row[column] in (8388607, -8388608) for row in sine + piano for column in ("new_left", "new_right")),
            "dryAtLimiterCeilingSamples": sum(abs(row[column]) == 4194303 for row in sine + piano for column in ("new_left", "new_right")),
            "limitedSineFrames": sum(row["limiter_gain_q16"] < 65536 for row in sine),
            "sampleRate": SAMPLE_RATE, "pianoVoiceCountVerified": 4,
            "pianoDemoSeconds": len(demo) / SAMPLE_RATE,
            "demoEnvelopeNote": "Testbench overrides generic attack/decay/release; piano-specific core remains unchanged. Not a full-board recording.",
            "warning": "Peak limiting can reduce loud chords and introduce compression artifacts; no promise of zero nonlinear distortion."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    result = {"audio": analyze_audio(args.capture, args.output), "hardwareTested": False}
    spec = importlib.util.spec_from_file_location("latency_reference", Path(__file__).with_name("analyze-touch-i2s-latency.py"))
    latency_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(latency_module)
    latency = {}
    for label, early, stable in (("baseline", 0, 0), ("gainOnly", 0, 1), ("gainAndEarly", 1, 1)):
        latency[label] = latency_module.analyze(args.capture / f"touch_i2s_latency_e{early}_s{stable}.csv")
    result["latency"] = latency
    before = latency["baseline"]["cases"]
    after = latency["gainAndEarly"]["cases"]
    improvements = [round(a["first_nonzero_i2s_us"] - b["first_nonzero_i2s_us"], 3) for a, b in zip(before, after)]
    if min(improvements) <= 700:
        raise ValueError(f"Early reporting did not save expected digital time: {improvements}")
    result["observedI2sSavingsUs"] = improvements
    result["analysisScriptSHA256"] = {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest().upper()
                                      for name in ("analyze-chord-touch.py", "analyze-touch-i2s-latency.py")}
    (args.output / "analysis.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    lines = ["# 和弦与触摸提前上报：仿真对照", "",
             "所有数据来自实际RTL仿真。数字延迟起点为MPR121已滤波状态寄存器变更，终点为外部I2S完整非零字。",
             "", "| 场景 | 旧版/μs | 只改混音/μs | 混音＋提前上报/μs | 节省/μs |", "|---|---:|---:|---:|---:|"]
    for index in range(4):
        lines.append(f"| {index} | {before[index]['first_nonzero_i2s_us']:.3f} | "
                     f"{latency['gainOnly']['cases'][index]['first_nonzero_i2s_us']:.3f} | "
                     f"{after[index]['first_nonzero_i2s_us']:.3f} | {improvements[index]:.3f} |")
    ratios = result["audio"]["heldA4ComponentRatios"]
    lines += ["", "保持A4再增加E5，拟合原440Hz分量：",
              f"旧分档版本保留{ratios['old']:.6f}倍，新版保留{ratios['new']:.6f}倍。新旧单音稳定段PCM逐位一致。",
              "", "钢琴WAV使用相同24位标度与48kHz，先A4后加E5；没有分别归一化。测试台简化通用包络参数，属于算法对照，不能当作DAC录音。",
              "", "64声部正弦满载与4声部钢琴分开验证。阈值内不按声部数量降低增益，超阈值仍会压缩；不能承诺任何和弦都没有音量变化或非线性失真。",
              "", "完整43字节仍然读完，仅提前发布前两字节，减少首音等待，不提高整个滑条/触摸扫描周期。",
              "", "真实电极检测、MPR滤波、DAC/功放与空气传播未包含，≤5ms/≤10ms物理总延迟仍待实测。四个场景不是严格最坏上界或无抖动证明。"]
    (args.output / "对照结果.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps({"passed": True, "ratios": ratios, "i2sSavingsUs": improvements}, ensure_ascii=False))


if __name__ == "__main__":
    main()
