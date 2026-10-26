"""整理已验收的本地学习模式交付。拒绝未通过时序/输入哈希变化的位流，不上传或下载硬件。"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def copy(source, target):
    # 同名但不同内容时拒绝覆盖，避免把另一个已交付版本混进本次目录。
    if target.exists() and sha(source) != sha(target):
        raise ValueError(f"Refusing to replace a different delivered file: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    assert sha(source) == sha(target)


def copy_tree(source, target):
    for file in sorted(source.rglob("*")):
        if file.is_file():
            copy(file, target / file.relative_to(source))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--stage", required=True, type=Path)
    args = parser.parse_args()
    result = read(args.snapshot / "build-results.json")
    if not (result["buildAccepted"] and result["current"]["timingPass"] and
            result["sourceInputsMatch"] and result["snapshotInputsMatch"]):
        raise ValueError("Build, timing or frozen input verification did not pass")
    inputs = read(args.snapshot / "snapshot-inputs.json")
    for item in inputs:
        source = ROOT / item["path"]
        expected = item.get("expectedSourceSha256", item["sha256"])
        if sha(source) != expected.upper():
            raise ValueError(f"Working source differs from built source: {source}")
    verification = ROOT / "verification/learning-mode"
    unchanged = read(verification / "unchanged-inputs.json")
    for item in unchanged:
        if sha(Path(item["path"])) != item["sha256"].upper():
            raise ValueError(f"Unrelated audio/mobile file changed: {item['path']}")
    unit_log = (verification / "desktop-unit.log").read_text(encoding="utf-8-sig")
    browser_log = (verification / "browser.log").read_text(encoding="utf-8-sig")
    if "LEARNING DESKTOP PASS" not in unit_log or "LEARNING UI PASS" not in browser_log:
        raise ValueError("Learning desktop checks missing")
    if not read(verification / "ui/result.json")["passed"]:
        raise ValueError("Browser checks failed")
    if not read(verification / "windows-build/packaged-smoke-test.json")["ok"]:
        raise ValueError("Portable Windows smoke test failed")
    cases = []
    summaries = sorted((args.stage / "verification/modelsim").glob("*/test-summary.json"))
    for path in summaries:
        summary = read(path)
        manifest = read(path.parent / "manifest.json")
        if not (manifest.get("Passed") and manifest.get("InputsUnchanged") and
                all(case["Passed"] for case in summary)):
            raise ValueError(f"ModelSim run not accepted: {path}")
        cases.extend(case["Name"] for case in summary)
    if len(cases) != 19 or len(set(cases)) != 19:
        raise ValueError(f"Expected 19 distinct checked cases, got {len(cases)}")

    delivery = ROOT / "delivery-learning-mode"
    evidence = delivery / "evidence"
    fs_source = args.snapshot / "full/impl/pnr/ContestFull.fs"
    fs_target = delivery / "fpga/ContestFull_LearningMode1024.fs"
    copy(fs_source, fs_target)
    for item in inputs:
        copy(args.snapshot / item["path"], delivery / "fpga-source" / item["path"])
    for filename in ("build-results.json", "gowin-build.log", "gowin-run.json", "snapshot-inputs.json",
                     "snapshot-inputs-after.json", "snapshot-metadata.json", "gprj-dependencies.json"):
        copy(args.snapshot / filename, evidence / "fpga" / filename)
    for pattern in ("*.tr", "*.rpt.txt", "*.pin.html"):
        for file in (args.snapshot / "full/impl/pnr").glob(pattern):
            copy(file, evidence / "fpga" / file.name)
    # 交付报告、测试指令和波形；不重复打包ModelSim工作库及高云厂商仿真库。
    for summary in summaries:
        run = summary.parent
        target = evidence / "modelsim" / run.name
        for name in ("manifest.json", "inputs.json", "test-summary.json"):
            copy(run / name, target / name)
        for name in ("logs", "cases", "waves"):
            copy_tree(run / name, target / name)
    for folder in ("ui", "windows-build"):
        copy_tree(verification / folder, evidence / folder)
    for filename in ("desktop-unit.log", "browser.log", "stage.json", "unchanged-inputs.json"):
        copy(verification / filename, evidence / filename)
    doc_name = "等候学习模式_20261026.md"
    copy(ROOT / "docs" / doc_name, delivery / doc_name)
    # 核心RTL与Windows可维护文件已在主工程；快照只用于准确复建本次位流。
    before = read(ROOT / "delivery-direct-score/evidence/fpga/build-results.json")["current"]
    after = result["current"]
    resource_delta = {key: after["resources"][key]["used"] - before["resources"][key]["used"]
                      for key in after["resources"]}
    report = {
        "version": "1.5.0-local", "date": "2026-10-26", "hardwareTested": False,
        "bitstream": str(fs_target.relative_to(delivery)), "bitstreamSha256": sha(fs_target),
        "buildInputsMatchWorkingFiles": True, "checkedBuildInputs": len(inputs),
        "audioAndMobileUnchangedFiles": len(unchanged), "modelsimCases": cases,
        "desktopUnitSuites": 9, "browserSuites": 5, "packagedSmokePassed": True,
        "timing": after["minimumSlackNs"], "resources": after["resources"],
        "resourceDeltaFromDeliveredDirectScore": resource_delta,
        "knownLimits": ["minimum setup slack 0.002 ns", "existing clock/routing warnings retained",
                        "physical keys/BLE/LED25 remain untested", "GAO disabled only in build snapshot"]
    }
    (delivery / "manifest.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    table = "\n".join(f"| {key} | {before['resources'][key]['used']:g} | {after['resources'][key]['used']:g} / {after['resources'][key]['capacity']:g} | {resource_delta[key]:+g} |"
                      for key in after["resources"])
    (delivery / "验证结果.md").write_text(f"""# 学习模式本地验证结果（2026-10-26）

19项ModelSim用例、9组JavaScript单元回归、5组浏览器回归及Windows打包依赖自检实际通过。没有连接、下载或测试真实板卡。

ModelSim用例：{', '.join(cases)}。

新功能覆盖无限等待（仿真中长时间不按，状态机无超时跳转）、重复音、和弦缺键/多键、传感器故障恢复、结束、重启、停止、复位；UART/CRC回传、反压和同序号重试；真实整合RTL中蓝牙音符不能替代实体键过关。触摸采集边界注入模拟状态，未模拟实物手指电容。

Windows回归覆盖协议/取消/旧固件、控制队列不吞快速按键、模式同步、直接曲谱、上传、实时播放、键位自定义；浏览器覆盖学习、原有灯位图和指引、后台播放与快捷键。截图位于 evidence/ui。打包通过 smoke-test，源码网页与包内文件逐项哈希一致。

高云V1.9.12构建目标 GW5AT-LV60PG484AC1/I0，在**原有约束**下通过。音频域49.152MHz，输出48kHz；未改引脚/时序约束。Setup/Hold违反端点均为0，最小余量：

| 类别 | 余量 ns |
|---|---:|
| Setup | {after['minimumSlackNs']['setup']} |
| Hold | {after['minimumSlackNs']['hold']} |
| Recovery | {after['minimumSlackNs']['recovery']} |
| Removal | {after['minimumSlackNs']['removal']} |

**Setup仅0.002ns，余量很紧。**最差路径由performance的score_position到event_note。不能据此宣称实物长期稳定；之后改设计仍须重新构建。仍有{result['warningCount']}条构建警告（含CK3000时钟关系和PR1014 sys_clk_d通用布线提醒），本次未扩大范围修复原时钟架构，也未放宽约束掩盖问题。

| 资源 | 上次DirectScore交付 | 本次 / 总量 | 增量 |
|---|---:|---:|---:|
{table}

BSRAM未新增；104/118是整个主工程用量，不是学习器单独占用。DSP按工具的等效块单位报告。比较基准为实际交付的DirectScore，不是构建脚本JSON中更早的ModeSync历史比较。

{len(inputs)}个构建输入已和当前源文件核对；GAO仅在独立构建快照中禁用。{len(unchanged)}个音频/手机文件哈希未变。完整已构建源快照在 fpga-source，打开 fpga-source/full/ContestFull.gprj 可查看对应工程；此快照后续应复制到另一个目录修改。

位流SHA256：`{sha(fs_target)}`。

日志位置：evidence/modelsim、evidence/fpga、evidence/windows-build。新位流只放到fpga目录，没有覆盖旧位流、推送远端或自动下载。实物键盘、BLE、灯板类型/排列、长时间运行均待实测。
""", encoding="utf-8")
    (delivery / "README.md").write_text("""# 等候学习模式 1.5.0

- 软件：windows/TangNeonStudio/TangNeonStudio.exe（保留整个文件夹）。
- 下载文件：fpga/ContestFull_LearningMode1024.fs，Gowin Programmer选 SRAM Program。
- 对应GUI工程：fpga-source/full/ContestFull.gprj。
- 选内置或25键映射曲谱，进入演奏页，点击“等我弹对”。每一步先松开全部琴键，再按目标；和弦须按齐，不多按。无等待超时。
- 原来的节奏指引仍保留；直接音高/实时播放曲谱不支持此模式。真实学习仅判断实体触摸琴键。
- 旧FPGA位流不支持新学习功能；C3固件无需更新。手机版本次不新增学习入口。
- 完整用法和模块说明见“等候学习模式_20261026.md”，实测范围和时序限制见“验证结果.md”。

本版通过仿真及现有约束下时序检查；最小Setup余量仅0.002ns。尚未上板，不能宣称长期运行和灯位对应已验证。
""", encoding="utf-8")
    print(json.dumps({"delivery": str(delivery), "modelsim": len(cases), "bitstreamSha256": sha(fs_target),
                      "buildInputs": len(inputs), "resourcesDelta": resource_delta}, ensure_ascii=False))


if __name__ == "__main__":
    main()
