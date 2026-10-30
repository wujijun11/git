"""运行与延音相关的协议/界面/原生调度回归，逐项保存命令、退出码和日志。"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--node", default="C:/node.js/node.exe")
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--browser", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "verification/sustain/clients-final")
    parser.add_argument("--java-home", default="C:/Program Files/Java/jdk-17")
    parser.add_argument("--android-jar", default=str(ROOT.parents[1] / "TangMega60K_Synth/tmp/android-build/sdk/platforms/android-35/android.jar"))
    args = parser.parse_args()
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    javascript = [
        "desktop/tests/test_sustain.js", "desktop/tests/test_controller.js",
        "desktop/tests/test_mode_sync.js", "desktop/tests/test_queue.js",
        "desktop/tests/test_native_lease.cjs", "desktop/tests/test_realtime_score.js",
        "desktop/tests/test_learning.cjs", "desktop/tests/test_score_upload.js",
        "mobile/tests/test_protocol.js", "mobile/tests/test_app_simulation.js",
        "mobile/tests/test_app_async.js", "mobile/tests/test_midi.js",
    ]
    if args.browser:
        javascript.append("desktop/tests/test_sustain_ui.cjs")
    commands = [[args.python, "mobile/tests/make_midi_fixtures.py"]]
    commands.extend([args.node, path] for path in javascript)
    commands.extend([
        [args.python, "-m", "unittest", "discover", "-s", "desktop/tests", "-p", "test_*.py"],
        [args.python, "mobile/tests/test_protocol.py"],
        [args.python, "mobile/tests/test_ble_policy.py", "--java-home", args.java_home],
        [args.python, "mobile/tests/test_android_callbacks.py", "--java-home", args.java_home,
         "--android-jar", args.android_jar],
    ])
    # Android宿主检查是带参数的独立程序，不能当作unittest模块导入。
    for case in ("downloads", "export", "file"):
        commands.append([args.python, "mobile/tests/test_android_async.py", "--java-home", args.java_home,
                         "--android-jar", args.android_jar, "--case", case])
    environment = os.environ.copy()
    environment["JAVA_HOME"] = args.java_home
    environment["PATH"] = environment["JAVA_HOME"] + "/bin;" + environment.get("PATH", "")
    results = []
    for number, command in enumerate(commands):
        result = subprocess.run(command, cwd=ROOT, env=environment,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        name = f"{number:02d}_" + Path(command[-1]).stem.replace("*", "all") + ".log"
        (output / name).write_bytes(result.stdout)
        results.append({"command": command, "exitCode": result.returncode, "log": name,
                        "logSha256": hashlib.sha256(result.stdout).hexdigest().upper()})
        print(f"{'PASS' if result.returncode==0 else 'FAIL'} {' '.join(command[1:])}", flush=True)
    report = {"passed": all(item["exitCode"] == 0 for item in results),
              "commands": results, "hardwareTested": False}
    (output / "summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if not report["passed"]:
        raise SystemExit("存在未通过的客户端回归，查看独立日志")


if __name__ == "__main__":
    main()
