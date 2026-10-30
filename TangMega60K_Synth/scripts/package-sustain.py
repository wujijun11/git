"""把通过证据检查的延音位流、手机/电脑程序及对应源码封存为本地测试包。"""
import hashlib
import json
import re
import shutil
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "docs/reports/sustain-20261030"
OUTPUT = ROOT / "delivery-sustain"
DOC = "开关式延音与蓝牙控制实现说明_20261030.md"


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and sha(source) != sha(target):
        raise ValueError("不覆盖已有不同交付文件：" + str(target))
    shutil.copy2(source, target)
    if sha(source) != sha(target):
        raise ValueError("交付复制校验失败")


def verify():
    report = read(REPORT / "analysis.json")
    if not report["verified"] or report["hardwareTested"] or report["adoptedAsFinal"]:
        raise ValueError("延音测试版证据状态不正确")
    for item in read(REPORT / "SHA256.json"):
        if sha(REPORT / item["path"]) != item["sha256"]:
            raise ValueError("冻结证据被修改：" + item["path"])
    build = Path(report["sourceBuild"])
    entries = read(build / "snapshot-inputs.json")
    for item in entries:
        if sha(ROOT / item["path"]) != item.get("expectedSourceSha256", item["sha256"]).upper():
            raise ValueError("当前源码与位流构建版本不一致")
    fs = build / "full/impl/pnr/ContestFull.fs"
    if sha(fs) != report["bitstreamSha256"]:
        raise ValueError("位流与报告不一致")
    return report, build, entries, fs


def freeze_source(build, entries):
    source_root = OUTPUT / "source"
    for item in entries:
        copy(build / item["path"], source_root / item["path"])
    for source in (build / "full/rtl").rglob("*.hex"):
        copy(source, source_root / source.relative_to(build))
    # 仅列出Git管理或新增的源码；不带SDK、虚拟环境、缓存和开发签名私钥。
    listing = subprocess.check_output(["git", "-c", "core.quotepath=false", "ls-files", "-z",
                                       "--cached", "--others", "--exclude-standard"], cwd=ROOT)
    for name in listing.decode("utf-8").split("\0"):
        if name.startswith(("desktop/", "mobile/", "sim/", "scripts/", "licenses/")):
            copy(ROOT / name, source_root / name)
    for source in (ROOT / "full").glob("*.rao"):
        copy(source, source_root / "full" / source.name)
    copy(ROOT / "docs" / DOC, source_root / "docs" / DOC)
    copy(ROOT / "TEST_VERSION.md", source_root / "TEST_VERSION.md")
    for folder in ("selected", "captures"):
        for source in (ROOT / "docs/reports/chord-touch-20261028" / folder).iterdir():
            if source.is_file():
                copy(source, source_root / "docs/reports/chord-touch-20261028" / folder / source.name)
    return source_root


def make_zip(path, files):
    if path.exists():
        raise ValueError("压缩包已存在，保留原封存，请使用新的交付目录")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for file, name in files:
            archive.write(file, name)
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError("压缩包校验失败")


def main():
    report, build, entries, fs = verify()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    target_fs = OUTPUT / "fpga/ContestFull_ChordSustain_TEST1024.fs"
    copy(fs, target_fs)
    apk = Path(report["apps"]["apk"])
    if sha(apk) != report["apps"]["apkSha256"]:
        raise ValueError("APK与核对记录不一致")
    target_apk = OUTPUT / "android/TangSynthRemote-1.9-Sustain-20261030.apk"
    copy(apk, target_apk)
    exe = Path(report["apps"]["windowsExe"])
    if sha(exe) != report["apps"]["windowsExeSha256"]:
        raise ValueError("Windows程序与核对记录不一致")
    source_root = freeze_source(build, entries)
    copy(ROOT / "docs" / DOC, OUTPUT / "实现说明.md")
    for source in REPORT.rglob("*"):
        if source.is_file():
            copy(source, OUTPUT / "evidence" / source.relative_to(REPORT))
    readme = """# Chord延音独立测试版

默认延音关闭。原F571最终文件未改变；本包没有上板验收，没有自动下载或写Flash。

1. FPGA用`fpga/ContestFull_ChordSustain_TEST1024.fs`进行SRAM Program，UserCode为7D2F。
2. 滑条左长按→声音→第四区延音→第二区开启；第一分区关闭。设置后显示波形，触摸回音量。
3. Windows运行`windows/TangNeonStudio/TangNeonStudio.exe`，保留整个`_internal`文件夹。
4. 手机只需`android/`下的APK。电脑/手机择一连接Tang-Synth-C3，等待FPGA握手后操作延音开关。
5. 短按钢琴键松手，对比开关前后；关闭延音时仍按住的其他键应继续发声。全部停止会清除延音。

原F571不支持新开关，新客户端会显示禁用；C3无需重新烧录。
64个声部全部保留时，新音可能无法分配；关闭延音并等待尾音回收后恢复空槽。

完整源码统一在`source/`，Gowin入口`source/full/ContestFull.gprj`，顶层`board_contest_full_top`。
其中gprj是实际已验证构建副本，GAO关闭；保留原V2、PLL、引脚和约束。
`实现说明.md`解释原理、目录、协议、资源、问题、复现命令和实测范围，`evidence/`保存原始日志。

真实延音听感、蓝牙射频/最小化播放、OLED新菜单及长期稳定性待用户实测。
此版没有被认定为此前Flash启动异常的修复版。
"""
    (OUTPUT / "请先阅读.md").write_text(readme, encoding="utf-8")
    header = fs.read_text(encoding="ascii", errors="replace")[:1500]
    user_code = re.search(r"//UserCode:\s*(0x[0-9A-Fa-f]+)", header)[1]
    manifest = {"branch": report["branch"], "baseCommit": report["baseCommit"],
                "hardwareTested": False, "adoptedAsFinal": False, "pushed": False,
                "hdlCases": report["hdlCases"], "resources": report["resources"],
                "minimumSlackNs": report["minimumSlackNs"],
                "fpga": {"path": target_fs.relative_to(OUTPUT).as_posix(), "sha256": sha(target_fs), "userCode": user_code},
                "android": {"path": target_apk.relative_to(OUTPUT).as_posix(), "sha256": sha(target_apk), "versionCode": 11},
                "windows": {"path": exe.relative_to(OUTPUT).as_posix(), "sha256": sha(exe), "version": "1.5.2-sustain-test"},
                "originalF571Unchanged": True}
    (OUTPUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    windows_zip = OUTPUT / "TangNeonStudio-Windows-1.5.2-Sustain.zip"
    make_zip(windows_zip, [(file, ("TangNeonStudio/" + file.relative_to(exe.parent).as_posix()))
                           for file in sorted(exe.parent.rglob("*")) if file.is_file()])
    archive = OUTPUT / "ContestFull_ChordSustain_TEST1024.zip"
    files = [(file, file.relative_to(OUTPUT).as_posix()) for folder in ("source", "fpga", "evidence")
             for file in sorted((OUTPUT / folder).rglob("*")) if file.is_file()]
    files.extend((OUTPUT / name, name) for name in ("实现说明.md", "请先阅读.md", "manifest.json"))
    make_zip(archive, files)
    inventory = [{"path": file.relative_to(OUTPUT).as_posix(), "bytes": file.stat().st_size, "sha256": sha(file)}
                 for file in sorted(OUTPUT.rglob("*")) if file.is_file() and file.name != "SHA256.json"]
    (OUTPUT / "SHA256.json").write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"delivery": str(OUTPUT), "files": len(inventory), "userCode": user_code,
                      "fpgaSha256": sha(target_fs), "apkSha256": sha(target_apk), "hardwareTested": False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
