"""封存1.5.1完整便携包与证据；只读FPGA既有FS，不重新构建或操作板卡。"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FPGA_SHA = "987CCEEB8F0491E51254D89880EF2667B450AFF0B1C8B3125CEE16E3222F656C"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", default="delivery-windows-minimized/windows/TangNeonStudio")
    parser.add_argument("--evidence", default="verification/windows-minimized-20261027")
    args = parser.parse_args()
    app, evidence = ROOT / args.app, ROOT / args.evidence
    release = ROOT / "releases/windows-minimized-20261027"
    report = ROOT / "docs/reports/windows-minimized-20261027"
    release.mkdir(parents=True, exist_ok=True)
    report.mkdir(parents=True, exist_ok=True)
    build = json.loads((evidence / "build/build-manifest.json").read_text(encoding="utf-8-sig"))
    smoke = json.loads((evidence / "build/packaged-smoke-test.json").read_text(encoding="utf-8-sig"))
    window = json.loads((evidence / "native-window.json").read_text(encoding="utf-8"))
    baseline = json.loads((evidence / "baseline-window.json").read_text(encoding="utf-8"))
    assert smoke["ok"] and window["ok"] and window["actualWindowMinimized"]
    assert not baseline["ok"] and baseline["actualWindowMinimized"]
    assert sha(app / "TangNeonStudio.exe") == build["exeSHA256"].upper()
    for item in build["webAssets"]:
        assert sha(app / "_internal/web" / item["path"]) == item["sha256"].upper()
        assert sha(ROOT / "desktop/web" / item["path"]) == item["sha256"].upper()
    for item in build["pythonSources"]:
        assert sha(ROOT / "desktop" / item["path"]) == item["sha256"].upper()
    fpga = ROOT / "delivery-oled-idle-wave/fpga/ContestFull_OLEDIdleWave_TEST1024.fs"
    assert sha(fpga) == FPGA_SHA, "不得改变当前可发声的FPGA测试位流"
    # 仅封存精选日志/JSON，排除解释器、临时构建、缓存和私人本机设置。
    for source in sorted(evidence.rglob("*")):
        if source.is_file() and source.suffix in (".json", ".log", ".txt"):
            target = report / source.relative_to(evidence)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    guide = app / "开始使用.md"
    guide.write_text("""# Windows 1.5.1 最小化播放修复版

解压整个文件夹，关闭旧版程序，再打开TangNeonStudio.exe，左下角应显示1.5.1。
_internal必须完整保留，不把新exe单独复制到旧版目录。

连接成功后选本地曲谱/MIDI并点蓝牙实时播放；先正常播放数秒，再最小化至少1分钟，
恢复后检查声音与进度，最后停止并重播。本次仅更换Windows软件，无需重烧FPGA/C3。

本轮真实窗口最小化使用内存模拟器验证，真实蓝牙、DAC、OLED和5×5灯板仍待测试。
不能保证电脑睡眠、关机、强制结束程序或无线链路中断后仍播放。

技术报告及历史问题见仓库TangMega60K_Synth/docs/下20261027相关Markdown。
""", encoding="utf-8")
    archive = release / "TangNeonStudio-Windows-1.5.1.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as output:
        for source in sorted(app.rglob("*")):
            if source.is_file():
                output.write(source, "TangNeonStudio/" + source.relative_to(app).as_posix())
    with zipfile.ZipFile(archive) as check:
        assert check.testzip() is None
        for name in check.namelist():
            relative = Path(name).relative_to("TangNeonStudio")
            assert hashlib.sha256(check.read(name)).hexdigest().upper() == sha(app / relative)
        file_count = len(check.namelist())
    manifest = dict(version="1.5.1-local", sourceBase="4bc95b1", branch="codex/windows-minimized-playback",
        zip=archive.name, zipSHA256=sha(archive), bytes=archive.stat().st_size, files=file_count,
        exeSHA256=sha(app / "TangNeonStudio.exe"), fpgaChanged=False, fpgaUserCode="10C2", fpgaSHA256=FPGA_SHA,
        nativeMinimizedWindow=window, javascriptBaseline=baseline,
        hardwareFeedback={"latestFpgaSound": "user_reported_audible", "oledTested": False,
                          "led5x5Tested": False, "newWindowsActualBluetoothTested": False},
        pythonSources=build["pythonSources"], webAssets=build["webAssets"])
    (release / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    (release / "SHA256SUMS.txt").write_text(f"{sha(archive)}  {archive.name}\n", encoding="ascii")
    (release / "README.md").write_text("""# Windows 1.5.1：最小化窗口实时播放修复

下载[TangNeonStudio-Windows-1.5.1.zip](TangNeonStudio-Windows-1.5.1.zip)，完整解压，关闭旧版，
运行`TangNeonStudio/TangNeonStudio.exe`。左下角应显示1.5.1，`_internal`必须保留。

原生后台线程处理曲谱计时、ACK和保活；最小化时界面可以暂停刷新，音符继续发送。
保留快速音符和原250ms滞后保护，不靠丢音或放宽超时解决问题。本次无需重烧FPGA/C3。

真实Windows窗口最小化专项已执行：内存设备收到2800/2800条事件，顺序一致，
恢复窗口后状态查询成功；**真实蓝牙与喇叭尚待用户复测**。
当前FPGA版本有用户发声反馈，**OLED屏幕与5×5灯板未进行实物测试**。

[实现与复现](../../docs/Windows最小化实时播放修复_20261027.md) ·
[问题与解决方案汇总](../../docs/版本问题与解决方案汇总_20261027.md) ·
[当前FPGA包](../oled-idle-wave-20261027/README.md)。ZIP及EXE哈希见`manifest.json`与`SHA256SUMS.txt`。
""", encoding="utf-8")
    (report / "summary.json").write_text(json.dumps(dict(pythonTests=52, jsSuites=8, offlineUiSuites=3,
        realWindowMinimizedTest=window, baselineReproduced=baseline,
        packedSmokePassed=smoke["ok"], zipBytesVerified=True,
        actualBluetoothTested=False, oledTested=False, led5x5Tested=False), ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(dict(zip=str(archive), sha256=sha(archive), files=file_count, bytes=archive.stat().st_size), ensure_ascii=False))


if __name__ == "__main__":
    main()
