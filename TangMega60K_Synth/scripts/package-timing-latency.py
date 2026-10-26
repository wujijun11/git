"""核对构建、24项回归和数字延迟后，整理独立时序优化交付；保留旧OLED版。"""
import argparse
import difflib
import hashlib
import importlib.util
import json
import re
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CASES = {"transport_status_equivalence", "polar_margin_s1", "polar_margin_s2", "polar_margin_s3",
         "polar_margin_negative", "polar_margin_early_write", "touch_i2s_latency", "oled_timing_regression",
         "menu_system", "learning_mode", "learning_status", "learning_system", "direct_score", "direct_system",
         "performance", "performance_retrigger", "performance_commit", "global_panic", "mpr121_backpressure",
         "mpr121_capacity", "audio_i2s", "full_system", "menu_replay", "score_capacity_1024"}


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def copy(source, target):
    if target.exists():
        if sha(source) != sha(target):
            raise ValueError(f"Refusing to replace a different delivery file: {target}")
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    assert sha(source) == sha(target)


def copy_tree(source, target):
    for file in sorted(source.rglob("*")):
        if file.is_file():
            copy(file, target/file.relative_to(source))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--modelsim", type=Path, required=True)
    args = parser.parse_args()
    result = read(args.snapshot/"build-results.json")
    if not all(result[key] for key in ("buildAccepted", "sourceInputsMatch", "snapshotInputsMatch")):
        raise ValueError("Build/timing/source evidence not accepted")
    previous = ROOT/"delivery-oled-integration"
    old_manifest = read(previous/"manifest.json")
    assert sha(previous/old_manifest["bitstream"]) == old_manifest["sha256"]
    old = read(previous/"evidence/fpga/build-results.json")["current"]
    current = result["current"]
    # PLL数量不等同于布线资源余量；独立列出PRIMARY/LW，避免误称时钟资源充足。
    report = (args.snapshot/"full/impl/pnr/ContestFull.rpt.txt").read_text(encoding="utf-8-sig")
    clock_resources = {}
    for name in ("PRIMARY", "LW", "GCLK_PIN", "PLLA"):
        match = re.search(r"^\s*"+name+r"\s*\|\s*(\d+)/(\d+)\s*\|", report, re.M)
        if not match:
            raise ValueError(f"Missing clock resource {name}")
        clock_resources[name] = {"used":int(match[1]), "capacity":int(match[2])}
    if (current["minimumSlackNs"]["setup"] <= old["minimumSlackNs"]["setup"] or
            current["minimumSlackNs"]["hold"] <= old["minimumSlackNs"]["hold"]):
        raise ValueError("Both setup and hold must improve before selecting timing optimization delivery")
    inputs = read(args.snapshot/"snapshot-inputs.json")
    for item in inputs:
        if sha(ROOT/item["path"]) != item.get("expectedSourceSha256", item["sha256"]).upper():
            raise ValueError(f"Working source differs from build: {item['path']}")
    sim = read(args.modelsim/"manifest.json")
    cases = read(args.modelsim/"test-summary.json")
    if (not sim["Passed"] or not sim["InputsUnchanged"] or len(cases) != len(CASES) or
            {item["Name"] for item in cases} != CASES or not all(item["Passed"] for item in cases)):
        raise ValueError("All 24 selected ModelSim checks are required")
    sim_inputs = read(args.modelsim/"inputs.json")
    for item in sim_inputs:
        if item["Kind"] in {"RTL", "ROM", "Testbench", "Runner"}:
            relative = Path(item["StagedPath"])
            assert sha(args.modelsim/relative) == item["Sha256Before"].upper(), relative
            assert sha(ROOT/relative) == item["Sha256Before"].upper(), relative
    evidence = ROOT/"verification/timing-latency-20261026"
    before = read(evidence/"before-inputs.json")
    changes = [item["path"] for item in before if sha(ROOT/item["path"]) != item["sha256"].upper()]
    if set(changes) != {"rtl/audio/polar_lane.v", "rtl/performance/performance_controller.v", "rtl/instrument_full_system.v"}:
        raise ValueError(f"Unexpected production changes: {changes}")
    # 从当前通过测试的CSV重新分析，禁止复制不相干的旧结果冒充本轮测量。
    spec = importlib.util.spec_from_file_location("latency_analysis", ROOT/"scripts/analyze-touch-i2s-latency.py")
    analysis = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(analysis)
    latency = analysis.analyze(args.modelsim/"sim/audio_results/touch_i2s_latency.csv")
    summary = read(evidence/"analysis/latency-results.json")
    assert latency == summary
    delivery = ROOT/"delivery-timing-latency"
    copy(args.snapshot/"full/impl/pnr/ContestFull.fs", delivery/"fpga/ContestFull_TimingTouch_TEST1024.fs")
    for item in inputs:
        copy(args.snapshot/item["path"], delivery/"fpga-source"/item["path"])
    for file in (args.snapshot/"full/rtl").rglob("*.hex"):
        relative = file.relative_to(args.snapshot/"full")
        assert sha(file) == sha(ROOT/relative)
        copy(file, delivery/"fpga-source/full"/relative)
    for item in sim_inputs:
        if item["Kind"] in {"Testbench", "Runner", "Viewer"}:
            relative = Path(item["StagedPath"])
            copy(args.modelsim/relative, delivery/"fpga-source"/relative)
    for name in ("prepare-direct-score-verification.py", "build-contest-isolated.py",
                 "verify-timing-latency.ps1", "analyze-touch-i2s-latency.py"):
        copy(ROOT/"scripts"/name, delivery/"fpga-source/scripts"/name)
    copy(previous/"evidence/fpga/build-results.json", delivery/"fpga-source/verification/oled-baseline.json")
    copy_tree(ROOT/"licenses/menu-font", delivery/"fpga-source/licenses/menu-font")
    copy(ROOT/"docs/时序余量与触摸I2S延迟技术总结_20261026.md", delivery/"技术总结.md")
    copy(previous/"OLED接线与使用.md", delivery/"OLED接线.md")
    for name in ("build-results.json", "gowin-run.json", "gowin-build.log", "snapshot-inputs.json",
                 "snapshot-inputs-after.json", "snapshot-metadata.json"):
        copy(args.snapshot/name, delivery/"evidence/fpga"/name)
    for name in ("ContestFull.tr", "ContestFull.rpt.txt", "ContestFull.pin.html"):
        copy(args.snapshot/"full/impl/pnr"/name, delivery/"evidence/fpga"/name)
    for name in ("manifest.json", "test-summary.json", "inputs.json"):
        copy(args.modelsim/name, delivery/"evidence/modelsim"/name)
    for folder in ("logs", "cases"):
        copy_tree(args.modelsim/folder, delivery/"evidence/modelsim"/folder)
    copy(args.modelsim/"sim/audio_results/touch_i2s_latency.csv", delivery/"evidence/touch_i2s_latency.csv")
    copy_tree(evidence/"analysis", delivery/"analysis")
    if (evidence/"intermediate-r1").is_dir():
        copy_tree(evidence/"intermediate-r1", delivery/"evidence/intermediate-r1")
    if (evidence/"rejected-r2").is_dir():
        copy_tree(evidence/"rejected-r2", delivery/"evidence/rejected-r2")
    if (evidence/"intermediate-r4").is_dir():
        copy_tree(evidence/"intermediate-r4", delivery/"evidence/intermediate-r4")
    diff = []
    for relative in changes:
        old_file = evidence/"source-before"/relative
        diff += list(difflib.unified_diff(old_file.read_text(encoding="utf-8").splitlines(True),
                                        (ROOT/relative).read_text(encoding="utf-8").splitlines(True),
                                        fromfile="oled-baseline/"+relative, tofile="timing-touch/"+relative))
    (delivery/"源码修改.diff").write_text("".join(diff), encoding="utf-8")
    resource_delta = {key:current["resources"][key]["used"]-old["resources"][key]["used"] for key in current["resources"]}
    manifest = {"date":"2026-10-26", "hardwareTested":False,
                "status":"local test branch; not merged or pushed",
                "branch":"codex/timing-latency-oled",
                "bitstream":"fpga/ContestFull_TimingTouch_TEST1024.fs",
                "sha256":sha(delivery/"fpga/ContestFull_TimingTouch_TEST1024.fs"),
                "setupHoldImproved":True, "timing":current["minimumSlackNs"],
                "timingBefore":old["minimumSlackNs"], "resources":current["resources"],
                "resourceDelta":resource_delta, "productionChanges":changes,
                "clockResources":clock_resources,
                "buildInputsChecked":len(inputs), "modelSimCases":[item["Name"] for item in cases],
                "latency":latency}
    (delivery/"manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    rows = ["# 实际验证结果", "", "24项ModelSim检查通过（含两项预期注错拒绝），所有生产RTL与构建输入对应。",
            "", "| 时序余量/ns | OLED版 | 本版 |", "|---|---:|---:|"]
    rows += [f"| {key} | {old['minimumSlackNs'][key]:.3f} | {current['minimumSlackNs'][key]:.3f} |"
             for key in ("setup", "hold", "recovery", "removal")]
    rows += ["", "| 资源 | 使用/总量 | 增量 |", "|---|---:|---:|"]
    rows += [f"| {key} | {value['used']:g}/{value['capacity']:g} | {resource_delta[key]:+g} |"
             for key,value in current["resources"].items()]
    rows += ["", "Setup/Hold违反端点为0；完整警告保留在高云日志，不能写成无警告。约束、PLL、引脚和ROM参数未改。",
             "", "时钟资源："+"，".join(f"{key} {value['used']}/{value['capacity']}" for key,value in clock_resources.items())+"。PRIMARY/LW仍满，不能因逻辑单元有剩余就宣称所有资源宽裕。",
             "", f"已滤波触摸状态到首完整非零I2S字观测最大{latency['observedMaxUs']:.3f}μs，"
             "详见analysis/延迟分段结果.md；不包含MPR模拟检测/滤波或DAC，尚未证明整机≤5ms/≤10ms或无抖动。",
             "", "未下载板卡、未推送GitHub；旧OLED位流哈希核对未变。",
             "", f"位流SHA256：`{manifest['sha256']}`"]
    (delivery/"验证结果.md").write_text("\n".join(rows)+"\n", encoding="utf-8")
    (delivery/"README.md").write_text("""# 本地测试版：完整OLED主工程时序与触摸延迟

- 分支：codex/timing-latency-oled；只在本地，未合并或推送main。
- 下载：fpga/ContestFull_TimingTouch_TEST1024.fs，GW5AT-60B，SRAM Program；本次未下载板卡。
- GUI工程：fpga-source/full/ContestFull.gprj，保留整个fpga-source目录及full/rtl查找表。
- 功能沿用OLED＋等候学习版；Windows/C3/手机无需更新。四针OLED和其他引脚均不变。
- 原理/目录/问题处理：技术总结.md；量化结论：验证结果.md；原始日志：evidence。
- 复现：在fpga-source目录执行scripts/verify-timing-latency.ps1，传入Python/ModelSim路径；加-Build执行隔离Gowin构建。
- 延迟为数字仿真。传感器物理检测、DAC和声学总延迟待实测，不宣称整机已经达标。

旧delivery-oled-integration文件保留，未推送远程仓库。
""", encoding="utf-8")
    project=delivery/"fpga-source/full/ContestFull.gprj"
    assert all((project.parent/item.attrib["path"]).is_file()
               for item in ET.parse(project).findall("./FileList/File") if item.get("enable") != "0")
    print(json.dumps({"delivery":str(delivery), "sha256":manifest["sha256"], "timing":manifest["timing"],
                      "maxDigitalLatencyUs":latency["observedMaxUs"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
