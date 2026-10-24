"""Compile and execute the real sketch with deterministic host callback scheduling.

Requires Python 3 and an existing MSVC C++ installation. No tools are installed.
Each case uses a fresh process, so sketch-local static state starts clean.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import shutil

HERE=Path(__file__).resolve().parent
PROJECT=HERE.parent.parent
CASES=("first_write","malformed_close","late_write_close","queue_full_close",
       "uart_error_close","short_uart_close","same_loop_uart_error",
       "notify_retry_close","notify_accept","late_notify_status",
       "reconnect_first_write","reconnect_between_loops","partial_uart_timeout",
       "old_failure_new_session","stale_failure_cannot_unpoison",
       "failed_writes_do_not_fill_queue","diagnostic_endianness",
       "valid_nested_header","crc_error_recovery","deleted_byte_nested_recovery",
       "inserted_byte_nested_recovery","overlapping_header_recovery",
       "fragmented_all_boundaries","noise_then_fragmented_header",
       "consecutive_crc_errors","reconnect_partial_response","reconnect_queued_response",
       "ble_crc_left_for_fpga","crc_valid_future_version_transparent")

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline",action="store_true")
    parser.add_argument("--vcvars",type=Path)
    args=parser.parse_args()
    source=HERE/"baseline/ble_bridge.ino" if args.baseline else PROJECT/"firmware/ble_bridge/ble_bridge.ino"
    source_hash=sha(source)
    inputs=[source,Path(__file__).resolve(),HERE/"bridge_transport_test.cpp",*sorted((HERE/"stubs").rglob("*.h"))]
    before={str(p.relative_to(PROJECT)):sha(p) for p in inputs}
    stamp=datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    output=HERE/(('baseline-run_' if args.baseline else 'candidate-run_')+stamp)
    output.mkdir()
    for p in inputs:
        target=output/"sources"/p.relative_to(PROJECT)
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(p,target)
    vcvars=args.vcvars
    if vcvars is None:
        vswhere=Path(os.environ.get("ProgramFiles(x86)",r"C:\Program Files (x86)"))/"Microsoft Visual Studio/Installer/vswhere.exe"
        installations=subprocess.check_output([str(vswhere),"-all","-products","*","-property","installationPath"],text=True).splitlines()
        choices=[Path(p)/"VC/Auxiliary/Build/vcvars64.bat" for p in installations if p.strip()]
        vcvars=next((p for p in choices if p.exists()),None)
    if vcvars is None or not vcvars.exists():
        raise RuntimeError("Existing MSVC C++ tools were not found; supply --vcvars.")
    translation=output/"test.cpp"
    translation.write_text(('#define BASELINE_BRIDGE\n' if args.baseline else '')+'#define BRIDGE_SKETCH "'+source.as_posix()+'"\n#include "'+(HERE/"bridge_transport_test.cpp").as_posix()+'"\n',encoding="utf-8")
    exe=output/"bridge-tests.exe"
    command=f'cl /nologo /std:c++17 /EHsc /W4 /D CONFIG_IDF_TARGET_ESP32C3 /D ARDUINO_USB_CDC_ON_BOOT=1 /D CONFIG_NIMBLE_ENABLED=1 /I "{HERE / "stubs"}" /Fe:"{exe}" /Fo:"{output / "test.obj"}" "{translation}"'
    compile_script=output/"compile.cmd"
    compile_script.write_text(f'@echo off\nchcp 65001 >nul\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n{command}\nexit /b %errorlevel%\n',encoding="utf-8")
    compile_result=subprocess.run(["cmd.exe","/d","/c",str(compile_script)],cwd=output,text=True,encoding="utf-8",errors="replace",stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
    (output/"compile.log").write_text(compile_result.stdout,encoding="utf-8")
    report={"timestampUtc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "kind":"deterministic host stub regression; not RF/hardware validation",
            "source":str(source),"sourceSha256Before":source_hash,"baseline":args.baseline,
            "compilerSetup":str(vcvars),"compileExit":compile_result.returncode,"cases":[],"inputHashesBefore":before}
    if compile_result.returncode==0:
        for case in CASES:
            result=subprocess.run([str(exe),case],cwd=output,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=10)
            (output/(case+".log")).write_text(result.stdout,encoding="utf-8")
            passed=result.returncode==0 and result.stdout.strip()=="PASS "+case
            report["cases"].append({"name":case,"exitCode":result.returncode,"passed":passed,"log":case+".log"})
            print(result.stdout.strip())
    else:
        print(compile_result.stdout)
    report["sourceSha256After"]=sha(source)
    report["inputHashesAfter"]={str(p.relative_to(PROJECT)):sha(p) for p in inputs}
    report["inputsUnchanged"]=before==report["inputHashesAfter"]
    report["passed"]=sum(c["passed"] for c in report["cases"])
    report["failed"]=len(CASES)-report["passed"]
    report["accepted"]=report["compileExit"]==0 and report["inputsUnchanged"] and report["failed"]==0
    (output/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    print("Summary:",output/"summary.json")
    return 0 if report["accepted"] else 1

if __name__=="__main__":
    sys.exit(main())
