"""Run the installed, documented EasyEDA Pro CLI and preserve JSON evidence."""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
EXE = r"D:\lceda-pro\lceda-pro.exe"


def run(args, name):
    result = subprocess.run([EXE, *args], capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=300)
    (ROOT / "references" / (name + ".json")).write_text(result.stdout, encoding="utf-8")
    if result.stderr:
        (ROOT / "references" / (name + ".stderr.txt")).write_text(result.stderr, encoding="utf-8")
    data = json.loads(result.stdout.lstrip("\ufeff\r\n "))
    if not data.get("ok"):
        raise RuntimeError(json.dumps(data, ensure_ascii=False))
    return data


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--name", required=True)
    p.add_argument("--script")
    p.add_argument("--session")
    p.add_argument("args", nargs="*")
    a = p.parse_args()
    argv = a.args
    if a.script:
        session = a.session or json.loads((ROOT/"references"/"working-session.json").read_text(encoding="utf-8"))["value"]["sessionId"]
        argv = ["invoke", "--session", session, "--ext-uuid", "eda", "--code",
                Path(a.script).read_text(encoding="utf-8"), "--timeout", "60000"]
    data = run(argv, a.name)
    report = json.dumps(data, ensure_ascii=False, indent=2)
    if len(report)>16000:
        print(json.dumps(dict(ok=data['ok'], evidence=str(ROOT/'references'/(a.name+'.json')), durationMs=data.get('durationMs')), ensure_ascii=False))
    else:
        print(report)
