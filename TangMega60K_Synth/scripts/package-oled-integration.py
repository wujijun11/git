"""整理OLED完整工程交付：拒绝时序未通过、源文件漂移或缺少测试证据的候选位流。"""
import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def copy(source, target):
    if target.exists():
        if sha(source) != sha(target):
            raise ValueError(f"Refusing to replace a different delivery file: {target}")
        # Gowin产物可带只读属性；同内容重跑只核对，避免再次打开位流写入。
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    assert sha(source) == sha(target)


def tree(source, target):
    for file in sorted(source.rglob("*")):
        if file.is_file():
            copy(file, target / file.relative_to(source))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--modelsim", type=Path, required=True)
    args = parser.parse_args()
    result = read(args.snapshot / "build-results.json")
    if not (result["buildAccepted"] and result["current"]["timingPass"] and
            result["sourceInputsMatch"] and result["snapshotInputsMatch"]):
        raise ValueError("Build/timing/input checks have not passed; do not deliver candidate")
    inputs = read(args.snapshot / "snapshot-inputs.json")
    for item in inputs:
        if sha(ROOT / item["path"]) != item.get("expectedSourceSha256", item["sha256"]).upper():
            raise ValueError(f"Built input differs from working source: {item['path']}")
    sim = read(args.modelsim / "manifest.json")
    cases = read(args.modelsim / "test-summary.json")
    required_cases = {"oled_timing_regression", "oled_board", "oled_board_timing", "learning_system",
                      "direct_system", "menu_system", "oled_menu", "global_panic", "performance",
                      "performance_retrigger", "performance_commit", "performance_stage",
                      "score_capacity_1024", "learning_mode", "learning_status", "control_router",
                      "menu_replay", "mpr121_backpressure", "mpr121_capacity", "full_system"}
    if (not sim["Passed"] or not sim["InputsUnchanged"] or
            {case["Name"] for case in cases} != required_cases or
            len(cases) != len(required_cases) or not all(case["Passed"] for case in cases)):
        raise ValueError("Twenty selected ModelSim cases must all pass")
    # ModelSim不读取SDC；核对其实际编译的生产RTL与最终构建源完全一致。
    sim_inputs = read(args.modelsim / "inputs.json")
    testbenches = [item for item in sim_inputs if item["Kind"] == "Testbench"]
    for item in testbenches:
        relative = Path(item["StagedPath"])
        assert sha(args.modelsim / relative) == item["Sha256Before"].upper(), relative
        assert sha(ROOT / relative) == item["Sha256Before"].upper(), relative
    rtl_count = 0
    rom_count = 0
    for file in (args.modelsim / "rtl").rglob("*"):
        if file.is_file():
            assert sha(file) == sha(ROOT / "rtl" / file.relative_to(args.modelsim / "rtl")), file
            if file.suffix.lower() in {".v", ".sv"}:
                rtl_count += 1
            elif file.suffix.lower() == ".hex":
                rom_count += 1
    evidence_root = ROOT / "verification/oled-integration"
    frame = read(evidence_root / "preview/frame-result.json")
    assert frame["passed"] and frame["bytesCompared"] == 1024
    assert sha(args.modelsim / "sim/audio_results/oled_board_frame.hex") == frame["captureSha256"].upper()
    pins = read(evidence_root / "pin-check.json")
    assert pins["passed"]
    pin_html = (args.snapshot / "full/impl/pnr/ContestFull.pin.html").read_text(encoding="utf-8-sig")
    for signal, pad in (("oled_scl", "A20"), ("oled_sda", "B20")):
        row = re.search(r'<tr>\s*<td class="label">' + signal + r'</td>(.*?)</tr>', pin_html, re.S)
        assert row and f"<td>{pad}/2</td>" in row[1] and "<td>LVCMOS33</td>" in row[1], signal
    for item in read(evidence_root / "unchanged-inputs.json"):
        assert sha(Path(item["path"])) == item["sha256"], item["path"]
    previous = ROOT / "delivery-learning-mode"
    old = read(previous / "manifest.json")
    assert sha(previous / old["bitstream"]) == old["bitstreamSha256"]
    delivery = ROOT / "delivery-oled-integration"
    copy(args.snapshot / "full/impl/pnr/ContestFull.fs", delivery / "fpga/ContestFull_OLED_Learning1024.fs")
    for item in inputs:
        copy(args.snapshot / item["path"], delivery / "fpga-source" / item["path"])
    # Gowin GUI从full目录执行时，$readmemh相对该目录解析；随工程附上同哈希ROM，
    # 避免命令行构建成功、用户直接打开GUI工程却找不到字模/音源查找表。
    for file in (args.snapshot / "full/rtl").rglob("*.hex"):
        relative = file.relative_to(args.snapshot / "full")
        assert sha(file) == sha(ROOT / relative), relative
        copy(file, delivery / "fpga-source/full" / relative)
    # 同包保留测试源和入口，复制到其他电脑后仍可复现，不依赖临时目录。
    for item in testbenches:
        relative = Path(item["StagedPath"])
        copy(args.modelsim / relative, delivery / "fpga-source" / relative)
    for name in ("prepare-direct-score-verification.py", "build-contest-isolated.py",
                 "test-modelsim-full.ps1", "verify-oled-integration.ps1",
                 "verify-oled-integration.py", "check-oled-pin-map.py"):
        copy(ROOT / "scripts" / name, delivery / "fpga-source/scripts" / name)
    copy(previous / "evidence/fpga/build-results.json",
         delivery / "fpga-source/verification/learning-mode/build-results.json")
    tree(ROOT / "licenses/menu-font", delivery / "fpga-source/licenses/menu-font")
    tree(ROOT / "hardware/wiring31005", delivery / "fpga-source/hardware/wiring31005")
    for name in ("build-results.json", "gowin-run.json", "gowin-build.log", "snapshot-inputs.json",
                 "snapshot-inputs-after.json", "snapshot-metadata.json"):
        copy(args.snapshot / name, delivery / "evidence/fpga" / name)
    for name in ("ContestFull.tr", "ContestFull.rpt.txt", "ContestFull.pin.html"):
        copy(args.snapshot / "full/impl/pnr" / name, delivery / "evidence/fpga" / name)
    for name in ("manifest.json", "test-summary.json", "inputs.json"):
        copy(args.modelsim / name, delivery / "evidence/modelsim" / name)
    for folder in ("logs", "cases"):
        tree(args.modelsim / folder, delivery / "evidence/modelsim" / folder)
    copy(args.modelsim / "sim/audio_results/oled_board_frame.hex", delivery / "evidence/oled_board_frame.hex")
    tree(evidence_root / "preview", delivery / "preview")
    copy(evidence_root / "pin-check.json", delivery / "evidence/pin-check.json")
    if (evidence_root / "failed-build-r2").is_dir():
        tree(evidence_root / "failed-build-r2", delivery / "evidence/failed-build-r2")
    copy(ROOT / "docs/OLED完整工程接入_20261026.md", delivery / "OLED接线与使用.md")
    current = result["current"]
    before = read(previous / "evidence/fpga/build-results.json")["current"]
    delta = {name: current["resources"][name]["used"] - before["resources"][name]["used"] for name in current["resources"]}
    manifest = {"date": "2026-10-26", "hardwareTested": False, "buildAccepted": True,
                "bitstream": "fpga/ContestFull_OLED_Learning1024.fs",
                "sha256": sha(delivery / "fpga/ContestFull_OLED_Learning1024.fs"),
                "inputsMatch": len(inputs), "modelSimProductionFilesMatch": rtl_count,
                "modelSimRomFilesMatch": rom_count,
                "pnrPinsVerified": True,
                "modelSimCases": [case["Name"] for case in cases], "oledBytesMatched": 1024,
                "pins": pins["pins"], "timingSlackNs": current["minimumSlackNs"],
                "resources": current["resources"], "changeFromLearningMode": delta,
                "windowsClient": "../delivery-learning-mode/windows/TangNeonStudio/TangNeonStudio.exe"}
    (delivery / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    resource_rows = "\n".join(f"| {name} | {current['resources'][name]['used']:g}/{current['resources'][name]['capacity']:g} | {delta[name]:+g} |" for name in delta)
    (delivery / "验证结果.md").write_text(f"""# OLED接入版实际验证结果

日期2026-10-26，未连接、扫描或下载板卡。{len(cases)}项ModelSim用例全部通过：{', '.join(manifest['modelSimCases'])}。

完整板级顶层使用原厂PLL模型，从新增OLED外部引脚独立解码：初始化25字节、页地址24字节、屏幕数据1024字节；与独立文字/字模参考逐字节一致。首帧写入中实际改变滑条菜单，仍保持旧状态快照。模拟NACK时由板载KEY0启动真实曲谱，音频继续且无欠载；恢复ACK后重初始化并完成下一帧。复位释放SCL/SDA。默认100kHz专项实际检查tLOW≥4.7μs、tHIGH≥4μs，不用加速功能用例冒充默认时序。

完整菜单系统使用64声部配置；学习UART链路、直接音高UART链路、全局停止、MPR反压及OLED单元均实际复测。这不等同于本轮重新采集64个同时发声的频谱。板级功能测试只加速显示和菜单等待；它不表示实屏刷新率。原厂DDR输出模型需要GSR，首次测试台补齐后重新通过；首次构建发现新增SDC层级路径与实际网表的generate命名不同，按网表精确修正。

随后一次布线检查有14条Setup违反端点，最差-0.396ns。按路径修正：本地菜单改读独立TRANSPORT状态，内置曲谱译码纳入一拍行缓存，MPR无效拍不再清零payload而仍由valid控制消费。没有降低时钟、修改音色算法或放宽其他路径。新增用例核对内置旋律32条按下/松开事件、连续20拍反压、完整释放及独立动作状态；其余针对性回归一并通过。内置曲谱换行最多多等一拍，约20.35ns，不能据此代替总演奏延迟实测。

最终Gowin构建通过，Setup/Hold违反端点均为0。最小余量（ns）：{json.dumps(current['minimumSlackNs'], ensure_ascii=False)}。仍须关注较小余量、既有时钟关系/普通布线警告；完整原始日志保留，不能据此宣称实屏长期稳定或整机≤5ms。

| 资源 | 使用/总量 | 比旧LearningMode增量 |
|---|---:|---:|
{resource_rows}

{len(inputs)}个构建输入与当前源文件匹配，{rtl_count}份生产RTL及{rom_count}份ROM文件与本次ModelSim冻结输入一致；音频引擎、Windows和手机输入哈希未改变。旧LearningMode位流哈希核对仍一致。GAO仅在交付的独立构建快照中禁用，原工程和既有产物保留。

物理接线：SCL=A20/J13-15，SDA=B20/J13-16，VCC=3.3V，GND共地。参考两版60K核心和31005底板原图；未测现场电压/导通。真实OLED控制器、地址、亮屏、方向、模块上拉与长期使用仍待实测。

位流SHA256：`{manifest['sha256']}`。
""", encoding="utf-8")
    (delivery / "README.md").write_text("""# 完整主工程：OLED＋等候学习版

- 下载文件：fpga/ContestFull_OLED_Learning1024.fs（Gowin Programmer，GW5AT-60B，SRAM Program）。
- 对应工程：fpga-source/full/ContestFull.gprj。保留整个fpga-source目录。
- 软件继续用Windows 1.5.0，无需为OLED更换C3固件或手机客户端。
- OLED四线：GND→公共地，VCC→3.3V，SCL→J13-15，SDA→J13-16。断电接线，辨认pin1；不连接灯板5V端子。
- 默认128×64 SSD1306/SSD1315兼容、I²C地址0x3C。菜单长按最左区约1秒后松手进入，四区短触选择。
- 实际仿真/时序记录见“验证结果.md”，详细模块和接线见“OLED接线与使用.md”。预览来自数字总线解码，不是实屏照片。

尚未上板验收OLED。旧LearningMode交付保留，未自动下载或推送GitHub。
""", encoding="utf-8")
    print(json.dumps({"delivery": str(delivery), "bitstreamSha256": manifest["sha256"], "slack": current["minimumSlackNs"], "resourceDelta": delta}, ensure_ascii=False))


if __name__ == "__main__":
    main()
