"""校验真实I2C/I2S引脚仿真导出的时间戳，生成分段延迟与明确测量边界。"""
import argparse
import csv
import json
from pathlib import Path


def analyze(source):
    """输入时间戳单位ns；返回4个场景及观测范围，不外推物理最坏值。"""
    with source.open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.DictReader(stream))
    if len(rows) != 4:
        raise ValueError(f"Expected four completed latency cases, got {len(rows)}")
    cases = []
    for index, row in enumerate(rows):
        values = {name: int(value) for name, value in row.items()}
        if values["case_id"] != index or values["key_count"] != (25 if index == 3 else 1):
            raise ValueError("Unexpected case order or missing keys")
        start = values["status_ns"]
        if not (start < values["snapshot_ns"] <= values["first_event_ns"] <=
                values["last_event_ns"] and values["first_event_ns"] <=
                values["first_command_ns"] <= values["last_command_ns"] and
                values["first_command_ns"] <= values["first_nonzero_i2s_ns"]):
            raise ValueError(f"Case {index}: timestamps out of order")
        stages = {key.removesuffix("_ns") + "_us": round((value - start) / 1000, 3)
                  for key, value in values.items() if key.endswith("_ns") and key != "status_ns"}
        if max(stages["last_command_us"], stages["first_nonzero_i2s_us"]) > 5000:
            raise ValueError(f"Case {index}: digital latency exceeds 5 ms")
        cases.append({"case": index, "pollPhase": values["phase"], "irqUsed": bool(values["irq"]),
                      "keyCount": values["key_count"], **stages})
    delays = [case["first_nonzero_i2s_us"] for case in cases]
    return {"passed": True, "physicalTested": False,
            "startBoundary": "MPR121 already-filtered touch status register change in digital slave model",
            "endBoundary": "first complete nonzero 24-bit channel word decoded from exported I2S pins",
            "excluded": ["electrode/AFE acquisition", "MPR121 filtering", "DAC/amplifier/acoustic delay"],
            "nominalAudioHz": 49152000, "sampleRateHz": 48000, "i2cHz": 400000,
            "pollIntervalUs": 500, "voiceSlots": 64, "coldCalibrationWaitAccelerated": True,
            "steadyStateParametersUnchanged": True, "cases": cases,
            "observedMinUs": min(delays), "observedMaxUs": max(delays),
            "observedSpreadUs": round(max(delays)-min(delays), 3),
            "scopeNote": "Four finite cases; not an exhaustive worst-case bound or proof of zero jitter",
            "physicalAtMost5msProven": False, "physicalAtMost10msProven": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = analyze(args.capture)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output/"latency-results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    lines = ["# 触摸状态到I2S数字仿真结果", "",
             "起点为MPR121已滤波触摸状态改变，终点为外部I2S完整24位非零字。三组真实串行总线，64声部配置，原钢琴和ADSR。",
             "", "| 场景 | 按键数 | IRQ | 快照/μs | 首事件/μs | 首命令/μs | 全部命令/μs | 首非零I2S/μs |",
             "|---|---:|---|---:|---:|---:|---:|---:|"]
    for item in result["cases"]:
        lines.append(f"| {item['case']}（相位{item['pollPhase']}） | {item['keyCount']} | {'使用' if item['irqUsed'] else '仅轮询'} | "
                     f"{item['snapshot_us']:.3f} | {item['first_event_us']:.3f} | {item['first_command_us']:.3f} | "
                     f"{item['last_command_us']:.3f} | {item['first_nonzero_i2s_us']:.3f} |")
    lines += ["", f"四个场景观测范围{result['observedMinUs']:.3f}～{result['observedMaxUs']:.3f}μs，"
              f"跨度{result['observedSpreadUs']:.3f}μs。通过5ms数字通路门限；有限场景不代表严格最坏上界或无抖动。",
              "", "25键和弦记录首个非零混合样本及全部NoteOn命令，不能据此宣称已逐个分离验证25个声部的首音。",
              "", "**真实手指到声音的≤5ms/≤10ms均未由本测试证明。** 不包含电极采集、MPR滤波、DAC与喇叭。"
              "冷启动等待缩短，ready后400kHz/0.5ms轮询、I2S和ADSR保持生产参数。"]
    (args.output/"延迟分段结果.md").write_text("\n".join(lines)+"\n", encoding="utf-8")
    print(json.dumps({key:result[key] for key in ("passed", "observedMinUs", "observedMaxUs", "observedSpreadUs")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
