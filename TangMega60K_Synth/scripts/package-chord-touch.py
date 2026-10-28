"""核对最终源码、仿真和完整时序后封存本地测试版；不操作硬件、不推送。"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "docs/reports/chord-touch-20261028"
DOC = ROOT / "docs/和弦稳定混音与触摸提前上报实现说明_20261028.md"
CORE = {"stable_polar_n4", "stable_polar_n64", "mpr121_early_mailbox", "mpr121_frontend_early",
        "touch_i2s_latency", "touch_i2s_gain", "touch_i2s_early_gain", "stable_chord_n64",
        "stable_chord_piano", "stereo_peak_limiter"}
REGRESSION = {"hierarchy_board_timing", "hierarchy_pixels", "hierarchy_system", "hierarchy_board",
    "menu_hierarchy", "slider_expression", "oled_idle10", "slider_liveness", "oled_i2c_stream",
    "oled_wave_capture", "oled_idle_menu", "oled_wave_display", "oled_wave_board", "oled_wave_board_timing",
    "oled_volume", "oled_menu", "oled_volume_board", "slider_menu", "slider_performance",
    "slider_volume_control", "slider_volume_system", "menu_system", "menu_replay", "mode_status",
    "global_panic", "control_router", "expression_merge", "audio_boot_status", "audio_i2s",
    "headroom_smoothing_n64", "learning_system", "mpr121_frontend", "mpr121_backpressure",
    "mpr121_capacity", "transport_status_equivalence", "runtime_fx", "mpr121_i2c", "mpr121_timing",
    "audio_units", "audio_engine_n4", "runtime_fx_storage", "performance_retrigger", "event_fifo_pipeline", "note_arbiter"}


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        if sha(source) == sha(target):
            return
        raise ValueError("Refusing to overwrite a different frozen artifact: " + str(target))
    shutil.copy2(source, target)


def verify_sim(directory, expected, label_correction=False):
    manifest = read(directory / "manifest.json")
    cases = read(directory / "test-summary.json")
    if not manifest["Passed"] or not manifest["InputsUnchanged"] or {c["Name"] for c in cases} != expected:
        raise ValueError("Missing/failed ModelSim cases")
    if not all(c["Passed"] and not c["ExpectedRejection"] for c in cases):
        raise ValueError("Unexpected rejection/failure in positive regression")
    for item in read(directory / "inputs.json"):
        if item["Kind"] in {"RTL", "ROM", "Testbench", "Runner"} and sha(ROOT / item["StagedPath"]) != item["Sha256Before"].upper():
            # 此用例收尾只增加打印单位设置；要求除此一行外与原测试逐字相同，
            # 并在main中强制核对修正后单独复跑，不以旧源码冒充最终源码。
            if label_correction and item["StagedPath"] == "sim/tb_mpr121_early.sv":
                current = (ROOT / item["StagedPath"]).read_bytes()
                corrected_line = '        $timeformat(-9,0,"",0); // %t按ns打印；避免默认ps再误标为ns。\n'.encode("utf-8")
                original = current.replace(corrected_line, b"")
                if original != current and hashlib.sha256(original).hexdigest().upper() == item["Sha256Before"].upper():
                    continue
            raise ValueError("Final simulation source changed: " + item["StagedPath"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--core", type=Path, required=True)
    parser.add_argument("--regression", type=Path, required=True)
    parser.add_argument("--early-check", type=Path, required=True)
    args = parser.parse_args()
    build = read(args.build / "build-results.json")
    if not all(build.get(key) for key in ("buildAccepted", "sourceInputsMatch", "snapshotInputsMatch", "protectedImplUnchanged")):
        raise ValueError("Build/input integrity did not pass")
    if not build["current"]["timingPass"]:
        raise ValueError("Full timing failed; do not distribute the bitstream")
    verify_sim(args.core, CORE, label_correction=True)
    verify_sim(args.regression, REGRESSION, label_correction=True)
    verify_sim(args.early_check, {"mpr121_early_mailbox"})
    analysis = read(args.core / "analysis/analysis.json")
    if not analysis["audio"]["passed"] or not all(row["passed"] for row in analysis["latency"].values()):
        raise ValueError("Independent numeric analysis failed")
    for name, expected in analysis["analysisScriptSHA256"].items():
        if sha(ROOT / "scripts" / name) != expected:
            raise ValueError("Independent analysis script changed: " + name)
    build_inputs = read(args.build / "snapshot-inputs.json")
    for item in build_inputs:
        name = item["path"].replace("\\", "/")
        if sha(ROOT / name) != item.get("expectedSourceSha256", item["sha256"]).upper() or sha(args.build / name) != item["sha256"].upper():
            raise ValueError("Build source changed: " + name)
    previous = ROOT / "delivery-menu-hierarchy/fpga/ContestFull_MenuExpression_TEST1024.fs"
    if sha(previous) != "0D56B19F538878475D528494B2F13072302CCC65C8E2B34F6C8877CAB56831C7":
        raise ValueError("Previous menu firmware changed")
    fs = args.build / "full/impl/pnr/ContestFull.fs"
    artifact = next(row for row in build["current"]["artifacts"] if row["path"].endswith("ContestFull.fs"))
    if sha(fs) != artifact["sha256"].upper():
        raise ValueError("Bitstream/report mismatch")
    for name in ("build-results.json", "snapshot-inputs.json", "snapshot-inputs-after.json", "snapshot-metadata.json", "gowin-run.json", "gowin-build.log"):
        copy(args.build / name, REPORT / "selected" / name)
    for name in ("ContestFull.tr", "ContestFull.rpt.txt", "ContestFull.pin.html"):
        copy(args.build / "full/impl/pnr" / name, REPORT / "selected" / name)
    for label, source in (("core", args.core), ("regression", args.regression), ("early-label-correction", args.early_check)):
        for name in ("manifest.json", "test-summary.json", "inputs.json"):
            copy(source / name, REPORT / label / name)
        for file in (source / "logs").glob("*"):
            if file.suffix in (".log", ".exitcode"):
                copy(file, REPORT / label / "logs" / file.name)
    for file in (args.core / "sim/audio_results").iterdir():
        if file.name.startswith(("chord_", "touch_i2s_latency_")):
            copy(file, REPORT / "captures" / file.name)
    for file in (args.core / "analysis").iterdir():
        if file.is_file():
            copy(file, REPORT / "analysis" / file.name)
    # 逐文件核对本轮未计划修改的核心：波形/音色/包络/协议/PLL与约束。
    protected = ["rtl/audio/adsr.v", "rtl/audio/pitch_expression.v", "rtl/audio/polar_lane.v",
        "rtl/audio/fm_piano_lane.v", "rtl/audio/runtime_audio_fx.v", "rtl/voice_allocator_v2.v",
        "rtl/expression_controls_v2.v", "full/contest_full.cst", "full/contest_full.sdc"]
    protected += [str(path.relative_to(ROOT)).replace("\\", "/") for path in (ROOT / "rtl/audio/rom").glob("*.hex")]
    checks = []
    for name in protected:
        original = subprocess.check_output(["git", "show", "HEAD:TangMega60K_Synth/" + name], cwd=ROOT)
        expected = hashlib.sha256(original).hexdigest().upper()
        actual = sha(ROOT / name)
        if actual != expected:
            raise ValueError("Protected algorithm/protocol changed: " + name)
        checks.append({"path": name, "sha256": actual, "matchesBranchBase": True})
    REPORT.mkdir(parents=True, exist_ok=True)
    (REPORT / "protected-source-check.json").write_text(json.dumps(checks, ensure_ascii=False, indent=2), encoding="utf-8")
    delivery = ROOT / "delivery-chord-touch"
    for item in build_inputs:
        name = item["path"].replace("\\", "/")
        copy(args.build / name, delivery / "fpga-source" / name)
    for file in (args.build / "full/rtl").rglob("*.hex"):
        copy(file, delivery / "fpga-source/full" / file.relative_to(args.build / "full"))
    for directory in (args.core, args.regression):
        for item in read(directory / "inputs.json"):
            if item["Kind"] in {"Testbench", "Runner", "Viewer"}:
                name = item["StagedPath"]
                copy(ROOT / name if name == "sim/tb_mpr121_early.sv" else directory / name, delivery / "fpga-source" / name)
    for name in ("verify-chord-touch.ps1", "package-chord-touch.py", "analyze-chord-touch.py", "analyze-touch-i2s-latency.py",
                 "prepare-direct-score-verification.py", "build-contest-isolated.py"):
        copy(ROOT / "scripts" / name, delivery / "fpga-source/scripts" / name)
    for folder in ("scripts/templates", "licenses", "docs/reports/chord-touch-20261028"):
        for file in (ROOT / folder).rglob("*"):
            if file.is_file():
                copy(file, delivery / "fpga-source" / file.relative_to(ROOT))
    baseline = "docs/reports/menu-hierarchy-20261028/selected/build-results.json"
    copy(ROOT / baseline, delivery / "fpga-source" / baseline)
    copy(DOC, delivery / "fpga-source/docs" / DOC.name)
    copy(DOC, delivery / "实现说明.md")
    destination_fs = delivery / "fpga/ContestFull_ChordStable_EarlyTouch_TEST1024.fs"
    copy(fs, destination_fs)
    project = delivery / "fpga-source/full/ContestFull.gprj"
    for row in ET.parse(project).findall("./FileList/File"):
        if row.get("enable") != "0" and not (project.parent / row.attrib["path"]).is_file():
            raise ValueError("Missing GUI source dependency: " + row.attrib["path"])
    info = {"date": "2026-10-28", "sourceBase": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "branch": "codex/chord-gain-stable-20261028", "bitstream": str(destination_fs.relative_to(delivery)).replace("\\", "/"),
        "sha256": sha(fs), "userCode": re.search(r"//UserCode: (\S+)", fs.read_text()[:2048]).group(1),
        "coreCases": sorted(CORE), "regressionCases": sorted(REGRESSION), "caseCount": len(CORE | REGRESSION),
        "resources": build["current"]["resources"], "minimumSlackNs": build["current"]["minimumSlackNs"],
        "i2sSavingsUs": analysis["observedI2sSavingsUs"], "heldA4Ratios": analysis["audio"]["heldA4ComponentRatios"],
        "hardwareValidated": False, "physicalLatencyMeasured": False, "powerFaultFixed": False,
        "previousOledBasicUserFeedback": True, "newFirmwareOledHardwareValidated": False,
        "led5x5HardwareValidated": False, "downloadedByAgent": False, "pushed": False}
    (delivery / "manifest.json").write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    (delivery / "README.md").write_text("""# 和弦稳定混音＋触摸提前上报：本地测试版

- 下载文件：fpga/ContestFull_ChordStable_EarlyTouch_TEST1024.fs；GW5AT-60B，SRAM Program。
- GUI工程：fpga-source/full/ContestFull.gprj；需要整个fpga-source目录。
- 普通和弦不再只按声部数量减半；实际超出峰值余量时仍会压缩保护。
- 按键状态在前两字节收到后上报，滑条仍读取完整43字节；菜单操作保留。
- 54项ModelSim、PCM数值分析和完整时序已核对。没有自动下载、没有推送。
- 本版尚未上板；旧版OLED基本显示获用户确认，不代替本版完整实测；5×5待实测。
- 真实手指到声音延迟、长时稳定性、听感仍待实测，旧核心板熄灯问题未宣称修复。
- 技术总结及接入/回退方法见fpga-source/docs/和弦稳定混音与触摸提前上报实现说明_20261028.md。
""", encoding="utf-8")
    release = ROOT / "releases/chord-touch-20261028"
    release.mkdir(parents=True, exist_ok=True)
    archive = release / "ContestFull_ChordStable_EarlyTouch_TEST1024.zip"
    if archive.exists():
        raise ValueError("Release archive already exists; use a new release directory")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
        for file in sorted(delivery.rglob("*")):
            if file.is_file():
                output.write(file, file.relative_to(delivery).as_posix())
    with zipfile.ZipFile(archive) as check:
        if check.testzip() is not None:
            raise ValueError("ZIP CRC failed")
        for name in check.namelist():
            if hashlib.sha256(check.read(name)).hexdigest().upper() != sha(delivery / name):
                raise ValueError("ZIP/source mismatch: " + name)
    info.update(zip=archive.name, zipSHA256=sha(archive), zipBytes=archive.stat().st_size)
    (release / "manifest.json").write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    (release / "SHA256SUMS.txt").write_text(sha(archive) + "  " + archive.name + "\n", encoding="ascii")
    print(json.dumps({"delivery": str(delivery), "fsSHA256": sha(fs), "userCode": info["userCode"],
                      "zipSHA256": sha(archive), "caseCount": info["caseCount"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
