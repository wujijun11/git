"""核对29项回归、源文件哈希和实际STA后，打包第二轮独立测试版。"""
import argparse
import importlib.util
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("delivery_common", ROOT / "scripts/package-timing-latency.py")
COMMON = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMMON)
read, sha, copy, copy_tree = COMMON.read, COMMON.sha, COMMON.copy, COMMON.copy_tree
CASES = COMMON.CASES | {"event_fifo_pipeline", "score_upload_tracker", "note_event_pipeline",
                       "remote_note_watchdog", "watchdog_arbiter"}


def validate(snapshot, modelsim):
    """只有同一份生产RTL通过功能与时序，才允许生成可下载的交付目录。"""
    build = read(snapshot / "build-results.json")
    if not all(build.get(key) for key in ("buildAccepted", "sourceInputsMatch", "snapshotInputsMatch")):
        raise ValueError("构建、时序或源文件核对未通过")
    baseline_path = ROOT / "delivery-timing-latency/evidence/fpga/build-results.json"
    baseline = read(baseline_path)["current"]
    current = build["current"]
    bitstream = snapshot / "full/impl/pnr/ContestFull.fs"
    recorded = next(item for item in current["artifacts"] if item["path"].endswith("ContestFull.fs"))
    if sha(bitstream) != recorded["sha256"].upper():
        raise ValueError("位流与实际构建报告中的SHA256不符")
    if not current["timingPass"] or current["minimumSlackNs"]["setup"] <= baseline["minimumSlackNs"]["setup"]:
        raise ValueError("最终候选须通过所有STA检查，且Setup余量确实改善")
    inputs = read(snapshot / "snapshot-inputs.json")
    for item in inputs:
        if sha(ROOT / item["path"]) != item.get("expectedSourceSha256", item["sha256"]).upper():
            raise ValueError(f"当前源码与实际构建不同：{item['path']}")
    # 晶振/PLL、CST/SDC和所有音色ROM逐项与上一测试版核对。
    previous = read(ROOT / "delivery-timing-latency/evidence/fpga/snapshot-inputs.json")
    protected = [item for item in previous if item["path"].endswith((".hex", ".cst", ".sdc")) or
                 "/pll" in item["path"].lower() or "audio_clock" in item["path"].lower()]
    for item in protected:
        if sha(ROOT / item["path"]) != item.get("expectedSourceSha256", item["sha256"]).upper():
            raise ValueError(f"本轮不应更改的硬件/音色输入发生变化：{item['path']}")
    manifest = read(modelsim / "manifest.json")
    results = read(modelsim / "test-summary.json")
    if (not manifest["Passed"] or not manifest["InputsUnchanged"] or len(results) != len(CASES) or
            {item["Name"] for item in results} != CASES or not all(item["Passed"] for item in results)):
        raise ValueError("29项ModelSim检查未全部通过")
    sim_inputs = read(modelsim / "inputs.json")
    for item in sim_inputs:
        if item["Kind"] in {"RTL", "ROM", "Testbench", "Runner"}:
            relative = Path(item["StagedPath"])
            if sha(modelsim / relative) != item["Sha256Before"].upper() or sha(ROOT / relative) != item["Sha256Before"].upper():
                raise ValueError(f"仿真来源发生变化：{relative}")
    return build, baseline, inputs, sim_inputs, protected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--modelsim", type=Path, required=True)
    parser.add_argument("--first-candidate", type=Path, help="首个候选的实际报告目录，仅归档报告，不交付其位流")
    parser.add_argument("--second-candidate", type=Path, help="第二个候选的实际报告目录，仅归档报告")
    args = parser.parse_args()
    build, baseline, inputs, sim_inputs, protected = validate(args.snapshot, args.modelsim)
    current = build["current"]
    delivery = ROOT / "delivery-pipeline-round2"
    bitstream_name = "fpga/ContestFull_PipelineRound2_TEST1024.fs"
    copy(args.snapshot / "full/impl/pnr/ContestFull.fs", delivery / bitstream_name)
    # 保留完整工程输入和ROM搜索目录；交付GPRJ取自实际关闭GAO的构建副本。
    for item in inputs:
        copy(args.snapshot / item["path"], delivery / "fpga-source" / item["path"])
    for file in (args.snapshot / "full/rtl").rglob("*.hex"):
        copy(file, delivery / "fpga-source/full" / file.relative_to(args.snapshot / "full"))
    for item in sim_inputs:
        if item["Kind"] in {"Testbench", "Runner", "Viewer"}:
            copy(args.modelsim / item["StagedPath"], delivery / "fpga-source" / item["StagedPath"])
    for name in ("prepare-direct-score-verification.py", "build-contest-isolated.py", "verify-pipeline-round2.ps1",
                 "analyze-touch-i2s-latency.py", "package-timing-latency.py", "package-pipeline-round2.py"):
        copy(ROOT / "scripts" / name, delivery / "fpga-source/scripts" / name)
    copy(ROOT / "delivery-timing-latency/evidence/fpga/build-results.json",
         delivery / "fpga-source/verification/pipeline-round2-baseline.json")
    copy_tree(ROOT / "licenses/menu-font", delivery / "fpga-source/licenses/menu-font")
    copy(ROOT / "docs/时序流水线第二轮技术总结_20261026.md", delivery / "技术总结.md")
    for name in ("build-results.json", "gowin-run.json", "gowin-build.log", "snapshot-inputs.json",
                 "snapshot-inputs-after.json", "snapshot-metadata.json"):
        copy(args.snapshot / name, delivery / "evidence/fpga" / name)
    for suffix in ("tr", "rpt.txt", "pin.html"):
        copy(args.snapshot / f"full/impl/pnr/ContestFull.{suffix}", delivery / "evidence/fpga" / f"ContestFull.{suffix}")
    for folder in ("logs", "cases"):
        copy_tree(args.modelsim / folder, delivery / "evidence/modelsim" / folder)
    for name in ("manifest.json", "test-summary.json", "inputs.json"):
        copy(args.modelsim / name, delivery / "evidence/modelsim" / name)
    csv = args.modelsim / "sim/audio_results/touch_i2s_latency.csv"
    copy(csv, delivery / "evidence/touch_i2s_latency.csv")
    analysis_spec = importlib.util.spec_from_file_location("latency_analysis", ROOT / "scripts/analyze-touch-i2s-latency.py")
    analysis = importlib.util.module_from_spec(analysis_spec)
    analysis_spec.loader.exec_module(analysis)
    latency = analysis.analyze(csv)
    # 分析器同时输出JSON和中文分段结果，命令失败即停止交付。
    subprocess.run([sys.executable, str(ROOT / "scripts/analyze-touch-i2s-latency.py"),
                    str(csv), str(delivery / "analysis")], check=True)
    if args.first_candidate:
        for name in ("build-results.json", "gowin-build.log"):
            copy(args.first_candidate / name, delivery / "evidence/first-candidate" / name)
    if args.second_candidate:
        for name in ("build-results.json", "gowin-build.log"):
            copy(args.second_candidate / name, delivery / "evidence/second-candidate" / name)
    report = (args.snapshot / "full/impl/pnr/ContestFull.rpt.txt").read_text(encoding="utf-8-sig")
    clocks = {}
    for name in ("PRIMARY", "LW", "GCLK_PIN", "PLLA"):
        match = re.search(r"^\s*" + name + r"\s*\|\s*(\d+)/(\d+)\s*\|", report, re.M)
        if not match:
            raise ValueError(f"缺少时钟资源记录：{name}")
        clocks[name] = {"used": int(match[1]), "capacity": int(match[2])}
    git_revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    metadata = {"date": "2026-10-26", "branch": "codex/timing-resource-round2", "sourceRevision": git_revision,
                "hardwareValidated": False, "status": "local test; not merged, pushed or downloaded",
                "bitstream": bitstream_name, "sha256": sha(delivery / bitstream_name),
                "timing": current["minimumSlackNs"], "baselineTiming": baseline["minimumSlackNs"],
                "resources": current["resources"], "clockResources": clocks,
                "buildInputCount": len(inputs), "protectedInputsChecked": len(protected),
                "modelSimCases": sorted(CASES), "latency": latency}
    (delivery / "manifest.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    rows = ["# 本地测试版实际验证结果", "", "29项ModelSim检查通过，其中2项为预期注错拒绝。未上板。",
            "", "| 余量/ns | 上一测试版 | 本轮 |", "|---|---:|---:|"]
    rows += [f"| {key} | {baseline['minimumSlackNs'][key]:.3f} | {current['minimumSlackNs'][key]:.3f} |"
             for key in ("setup", "hold", "recovery", "removal")]
    rows += ["", "| 资源 | 上一测试版 | 本轮 | 增量 |", "|---|---:|---:|---:|"]
    rows += [f"| {key} | {baseline['resources'][key]['used']:g} | {value['used']:g} | "
             f"{value['used']-baseline['resources'][key]['used']:+g} |" for key, value in current["resources"].items()]
    rows += ["", "Setup/Hold违反端点为0。各项余量应分别看表，不能把个别项目改善写成所有项目改善。",
             "", "时钟资源：" + "，".join(f"{key} {value['used']}/{value['capacity']}" for key,value in clocks.items()) + "。",
             "", f"触摸已识别状态到首完整非零I2S字最大观测{latency['observedMaxUs']:.3f}μs；"
             "不包含传感器物理识别/滤波、DAC、功放和声学输出，整机≤5ms/≤10ms与无抖动仍待实测。",
             "", "原49.152MHz/48kHz/24位I2S、64声部、音色ROM、顶层引脚及约束保持；不修改蓝牙客户端。",
             "", "既有PR1014等警告保留，未通过虚假路径/多周期例外掩盖问题。",
             "", f"位流SHA256：`{metadata['sha256']}`"]
    (delivery / "验证结果.md").write_text("\n".join(rows) + "\n", encoding="utf-8")
    (delivery / "README.md").write_text("""# 第二轮本地测试：用寄存器改善时序

- 本地分支：codex/timing-resource-round2。原OLED版、上一TimingTouch测试版均保留。
- 位流：fpga/ContestFull_PipelineRound2_TEST1024.fs；GW5AT-60B，SRAM Program。未上板验证。
- GUI工程：fpga-source/full/ContestFull.gprj。必须保留整个fpga-source目录；GAO仅在交付副本关闭。
- 功能：沿用OLED、64复音、四区菜单、1024行曲谱、录放与等候学习；引脚和客户端不变。
- 原理/职责/问题处理见技术总结.md；实际结果见验证结果.md；原始报告见evidence。
- 复现：在fpga-source内执行scripts/verify-pipeline-round2.ps1，指定Python和ModelSimBin；加-Build运行Gowin。
- Python需要3.11+；中文工作路径可保留，但StageParent须指向可写的英文路径。
- 不宣称整机物理演奏延迟或64音实测频谱已经达标。
""", encoding="utf-8")
    project = delivery / "fpga-source/full/ContestFull.gprj"
    for item in ET.parse(project).findall("./FileList/File"):
        if item.get("enable") != "0" and not (project.parent / item.attrib["path"]).is_file():
            raise ValueError(f"GUI工程缺少依赖：{item.attrib['path']}")
    print(json.dumps({"delivery": str(delivery), "sha256": metadata["sha256"], "timing": metadata["timing"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
