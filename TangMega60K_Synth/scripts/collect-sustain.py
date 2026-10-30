"""核对延音版的冻结构建、34项HDL验证及客户端产物，归档可复核证据。"""
import argparse
import csv
import hashlib
import json
import re
import shutil
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "docs/reports/chord-touch-20261028"
CORE = {"sustain_gate_n4", "sustain_gate_n64", "sustain_allocator_n4", "sustain_allocator_n64",
        "sustain_router", "sustain_menu", "sustain_system", "sustain_full64",
        "sustain_neutral_n4", "sustain_neutral_n64"}
REGRESSION = {"stable_polar_n4", "stable_polar_n64", "stable_chord_n64", "stable_chord_piano",
              "audio_units", "audio_i2s", "full_system", "menu_hierarchy", "hierarchy_pixels",
              "hierarchy_system", "hierarchy_board", "hierarchy_board_timing", "slider_expression",
              "oled_idle10", "oled_i2c_stream", "global_panic", "learning_system", "remote_uart",
              "mpr121_frontend_early", "touch_i2s_early_gain", "runtime_fx", "mode_status",
              "direct_capability", "learning_status"}
CHANGED = {"full/ContestFull.gprj", "rtl/board/board_contest_full_top.v", "rtl/instrument_full_system.v",
           "rtl/control/menu_hierarchy.v", "rtl/control/remote_command_router.v",
           "rtl/visual/oled_hierarchy_renderer.v", "rtl/visual/oled_status_display.v",
           "rtl/audio/rom/menu_hierarchy_font.hex"}


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    if sha(source) != sha(target):
        raise ValueError("证据复制不一致：" + str(source))


def verify_sim(run, expected):
    manifest = read(run / "manifest.json")
    cases = read(run / "test-summary.json")
    if not manifest["Passed"] or not manifest["InputsUnchanged"]:
        raise ValueError("HDL运行未通过或输入变化：" + str(run))
    if {case["Name"] for case in cases} != expected or not all(case["Passed"] for case in cases):
        raise ValueError("HDL用例集合不正确")
    for item in read(run / "inputs.json"):
        if item["Kind"] in {"RTL", "ROM", "Testbench", "Runner"}:
            if sha(ROOT / item["StagedPath"]) != item["Sha256Before"].upper():
                raise ValueError("当前测试源码与已验证版本不一致：" + item["StagedPath"])


def resource_table(path):
    text = path.read_text(encoding="utf-8-sig", errors="replace")
    result = {}
    for name in ("Logic", "Register", "CLS", "BSRAM", "DSP", "PRIMARY", "LW", "PLLA"):
        match = re.search(r"^\s*" + name + r"\s*\|\s*(\d+)/(\d+)\s*\|", text, re.M)
        if not match:
            raise ValueError("缺少资源报告项：" + name)
        result[name] = {"used": int(match[1]), "capacity": int(match[2])}
    return result


def verify_apps(clients):
    report = read(clients / "summary.json")
    if not report["passed"] or len(report["commands"]) != 21:
        raise ValueError("客户端最终检查不完整")
    for item in report["commands"]:
        if item["exitCode"] or sha(clients / item["log"]) != item["logSha256"]:
            raise ValueError("客户端日志检查失败")
    windows = read(ROOT / "verification/sustain/windows-build/build-manifest.json")
    exe = Path(windows["executable"])
    if sha(exe) != windows["exeSHA256"] or not read(ROOT / "verification/sustain/windows-build/packaged-smoke-test.json")["ok"]:
        raise ValueError("Windows安装包自检或哈希失败")
    for item in windows["webAssets"]:
        if sha(ROOT / "desktop/web" / item["path"]) != item["sha256"]:
            raise ValueError("Windows界面与封存版本不同")
        if sha(exe.parent / "_internal/web" / item["path"]) != item["sha256"]:
            raise ValueError("Windows包内界面不同")
    for item in windows["pythonSources"]:
        if sha(ROOT / "desktop" / item["path"]) != item["sha256"]:
            raise ValueError("Windows原生源码与封存版本不同")
    apk = ROOT / "mobile/android/output/TangSynthRemote-debug.apk"
    metadata = read(ROOT / "mobile/android/app/build/outputs/apk/debug/output-metadata.json")["elements"][0]
    if metadata["versionName"] != "1.9-sustain-test" or metadata["versionCode"] != 11:
        raise ValueError("Android版本不正确")
    with zipfile.ZipFile(apk) as archive:
        if archive.testzip() is not None:
            raise ValueError("APK损坏")
        for item in (ROOT / "mobile/web").rglob("*"):
            if item.is_file() and archive.read("assets/" + item.relative_to(ROOT / "mobile/web").as_posix()) != item.read_bytes():
                raise ValueError("APK网页与源码不同")
    lint = ET.parse(ROOT / "mobile/android/app/build/reports/lint-results-debug.xml").getroot()
    if any(item.get("severity") in {"Fatal", "Error", "Warning"} for item in lint.findall("issue")):
        raise ValueError("Android lint不为零")
    log = (ROOT / "verification/sustain/android-build.log").read_text(encoding="utf-8-sig", errors="replace")
    if "BUILD SUCCESSFUL" not in log or not all(text in log for text in (
        "Verified using v1 scheme (JAR signing): true", "Verified using v2 scheme (APK Signature Scheme v2): true")):
        raise ValueError("Android构建或签名校验未通过")
    if not read(ROOT / "verification/sustain/browser/summary.json")["passed"]:
        raise ValueError("真实页面检查未通过")
    return {"clientCommands": 21, "fixtureCommands": 1, "hardwareTested": False,
            "windowsExe": str(exe), "windowsExeSha256": sha(exe),
            "apk": str(apk), "apkSha256": sha(apk), "androidVersion": metadata["versionName"],
            "androidVersionCode": metadata["versionCode"], "androidLintErrors": 0, "androidLintWarnings": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("build", "core", "regression", "clients"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "docs/reports/sustain-20261030")
    parser.add_argument("--f571-file", type=Path, help="复核用的原F571位流，外部复现时可显式指定")
    args = parser.parse_args()
    verify_sim(args.core, CORE)
    verify_sim(args.regression, REGRESSION)
    apps = verify_apps(args.clients)
    build = read(args.build / "build-results.json")
    for key in ("buildAccepted", "sourceInputsMatch", "snapshotInputsMatch", "protectedImplUnchanged"):
        if not build[key]:
            raise ValueError("构建未通过：" + key)
    if not build["current"]["timingPass"]:
        raise ValueError("静态时序未通过")
    for item in read(args.build / "snapshot-inputs.json"):
        if sha(ROOT / item["path"]) != item.get("expectedSourceSha256", item["sha256"]).upper():
            raise ValueError("当前构建源码已变化：" + item["path"])
        if sha(args.build / item["path"]) != item["sha256"].upper():
            raise ValueError("冻结构建输入已变化")
    protected = []
    for item in read(BASE / "selected/snapshot-inputs.json"):
        path = item["path"].replace("\\", "/")
        if path not in CHANGED:
            if sha(ROOT / path) != item.get("expectedSourceSha256", item["sha256"]).upper():
                raise ValueError("改变了受保护的F571音源/接口/约束：" + path)
            protected.append(path)
    final = args.f571_file or ROOT.parents[1] / "final-chord-F571-20261029/fpga/ContestFull_ChordStable_EarlyTouch_TEST1024.fs"
    if sha(final) != "2F54A832EE9DFC616CA7BB35A6B6D5899CDB7BC5D6FB4B1439FAF37A17A44DDB":
        raise ValueError("原F571最终文件被改变")
    comparisons = {}
    for name in ("chord_piano_compare.csv", "chord_sine_compare.csv"):
        current = args.regression / "sim/audio_results" / name
        if sha(current) != sha(BASE / "captures" / name):
            raise ValueError("原版参数的数字样本或延迟改变：" + name)
        comparisons[name] = {"bitExact": True, "sha256": sha(current)}
    latency_name = "touch_i2s_latency_e1_s1.csv"
    with (BASE / "captures" / latency_name).open(newline="") as handle:
        old_rows = list(csv.DictReader(handle))
    latency_file = args.regression / "sim/audio_results" / latency_name
    with latency_file.open(newline="") as handle:
        new_rows = list(csv.DictReader(handle))
    if len(old_rows) != 4 or len(new_rows) != 4:
        raise ValueError("数字延迟场景不完整")
    latency_cases = []
    for old, new in zip(old_rows, new_rows):
        if any(old[key] != new[key] for key in ("case_id", "phase", "irq", "key_count")):
            raise ValueError("数字延迟场景身份不一致")
        old_delay = int(old["first_nonzero_i2s_ns"]) - int(old["status_ns"])
        new_delay = int(new["first_nonzero_i2s_ns"]) - int(new["status_ns"])
        if new_delay != old_delay:
            raise ValueError("所测场景的状态到I2S延迟不同")
        command_delta = (int(new["first_command_ns"]) - int(new["status_ns"]) -
                         int(old["first_command_ns"]) + int(old["status_ns"]))
        latency_cases.append({"case": int(new["case_id"]), "beforeNs": old_delay,
                              "afterNs": new_delay, "firstCommandDeltaNs": command_delta})
    comparisons[latency_name] = {"rawCsvBitExact": sha(latency_file) == sha(BASE / "captures" / latency_name),
        "caseRelativeI2sDelayEqual": True, "cases": latency_cases, "sha256": sha(latency_file)}
    pixels = read(ROOT / "verification/sustain/analysis/analysis.json")
    if not pixels["pixels"]["passed"] or not all(item["bitExact"] for item in pixels["neutral"].values()):
        raise ValueError("独立像素或中性PCM不一致")
    before = resource_table(BASE / "selected/ContestFull.rpt.txt")
    after = resource_table(args.build / "full/impl/pnr/ContestFull.rpt.txt")
    resources = {name: {"baseline": before[name]["used"], "current": after[name]["used"],
                       "delta": after[name]["used"] - before[name]["used"], "capacity": after[name]["capacity"]} for name in before}
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    for item in args.build.iterdir():
        if item.is_file() and item.suffix in {".json", ".log"}:
            copy(item, output / "selected" / item.name)
    for name in ("ContestFull.rpt.txt", "ContestFull.tr", "ContestFull.pin.html"):
        copy(args.build / "full/impl/pnr" / name, output / "selected" / name)
    for group, run in (("core", args.core), ("regression", args.regression)):
        for name in ("manifest.json", "inputs.json", "test-summary.json"):
            copy(run / name, output / group / name)
        for folder, extensions in (("logs", {".log"}), ("sim/audio_results", {".csv", ".hex"})):
            for source in (run / folder).glob("*"):
                if source.is_file() and source.suffix in extensions:
                    copy(source, output / group / ("logs" if folder == "logs" else "captures") / source.name)
    for source in (ROOT / "verification/sustain").rglob("*"):
        # 冻结轻量证据，排除可执行依赖与Gowin/ModelSim临时库。
        if source.is_file() and source.suffix in {".json", ".log", ".png"}:
            copy(source, output / "clients" / source.relative_to(ROOT / "verification/sustain"))
    fs = args.build / "full/impl/pnr/ContestFull.fs"
    fs_record = next(item for item in build["current"]["artifacts"] if item["path"].endswith("ContestFull.fs"))
    if sha(fs) != fs_record["sha256"].upper():
        raise ValueError("位流与报告不一致")
    report = {"verified": True, "hardwareTested": False, "adoptedAsFinal": False, "pushed": False,
              "baseCommit": "df6e8f6f8fcc60a31d0ff549eab37640f67aa4f7", "branch": "codex/sustain-20261030",
              "hdlCases": {"core": 10, "regression": 24, "total": 34}, "apps": apps,
              "protectedBaselineInputs": protected, "originalF571Unchanged": True,
              "baselineComparisons": comparisons, "independentAnalysis": pixels, "resources": resources,
              "minimumSlackNs": build["current"]["minimumSlackNs"],
              "sourceBuild": str(args.build), "bitstreamSha256": sha(fs)}
    (output / "analysis.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    inventory = [{"path": path.relative_to(output).as_posix(), "sha256": sha(path)}
                 for path in sorted(output.rglob("*")) if path.is_file() and path.name != "SHA256.json"]
    (output / "SHA256.json").write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"verified": True, "hdlCases": 34, "protectedInputs": len(protected),
                      "resources": resources, "timing": report["minimumSlackNs"], "apps": apps}, ensure_ascii=False))


if __name__ == "__main__":
    main()
