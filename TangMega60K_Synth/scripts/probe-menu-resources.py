"""在独立快照中综合OLED和不同曲谱容量，不生成或下载板卡程序。

综合统计用于比较模块增量；最终能否放入整机，仍以整机布局布线和时序为准。
只在曲谱探针的副本中替换SCORE_CAPACITY默认值，工作源码和公共接口保持不变。
"""
import argparse
import datetime as dt
import hashlib
import json
import re
import shutil
import subprocess
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
DEVICE = '<Device name="GW5AT-60B" pn="GW5AT-LV60PG484AC1/I0">gw5at60b-002</Device>'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stage(root, name, sources, top, capacity=None, split_generate=False):
    folder = root / name
    folder.mkdir(parents=True)
    inputs = []
    for relative in sources:
        source = PROJECT / relative
        target = folder / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        entry = {"path": relative, "sourceSha256": digest(source)}
        if capacity is not None and relative.endswith("performance_controller.v"):
            text = target.read_text(encoding="utf-8")
            declarations = re.findall(r"parameter integer SCORE_CAPACITY = [0-9]+,", text)
            if len(declarations) != 1:
                raise ValueError("曲谱容量默认声明发生变化，请核对探针")
            original = declarations[0]
            text = text.replace(original, f"parameter integer SCORE_CAPACITY = {capacity},")
            if split_generate:
                original_loop = '''    genvar row;
    generate for (row=0;row<SCORE_CAPACITY;row=row+1) begin: uploaded_rows
        assign written_or_unused[row]=row_written[row] || arg_count<=row;
    end endgenerate'''
                grouped_loop = '''    genvar group_index, local_row;
    generate for (group_index=0;group_index<(SCORE_CAPACITY+1023)/1024;group_index=group_index+1) begin: row_groups
        for(local_row=0;local_row<1024;local_row=local_row+1) begin: rows
            if(group_index*1024+local_row<SCORE_CAPACITY)begin: used
                assign written_or_unused[group_index*1024+local_row]=
                    row_written[group_index*1024+local_row] || arg_count<=group_index*1024+local_row;
            end
        end
    end endgenerate'''
                if text.count(original_loop) != 1:
                    raise ValueError("逐行检查结构发生变化，请核对探针")
                text = text.replace(original_loop, grouped_loop)
            target.write_text(text, encoding="utf-8")
            entry["transform"] = f"SCORE_CAPACITY={capacity} in snapshot only"
            entry["groupedGenerate"] = split_generate
        entry["snapshotSha256"] = digest(target)
        inputs.append(entry)
    files = "\n".join(f'<File path="{relative}" type="file.verilog" enable="1"/>'
                      for relative in sources if relative.endswith(".v"))
    (folder / "Probe.gprj").write_text(
        f'<?xml version="1.0" encoding="UTF-8"?><Project><Template>FPGA</Template>'
        f'<Version>5</Version>{DEVICE}<FileList>{files}</FileList></Project>', encoding="utf-8")
    (folder / "synth.tcl").write_text(
        'open_project [file join [file dirname [info script]] Probe.gprj]\n'
        f'set_option -top_module {top}\nset_option -vccx 1.8\nrun syn\n', encoding="ascii")
    (folder / "inputs.json").write_text(json.dumps(inputs, indent=2), encoding="utf-8")
    return folder, inputs


def synth(folder, inputs, gowin):
    with (folder / "synthesis.log").open("wb") as log:
        process = subprocess.Popen([str(gowin), str(folder / "synth.tcl")], cwd=folder,
                                   stdout=log, stderr=subprocess.STDOUT)
        try:
            code = process.wait(timeout=240)
        except subprocess.TimeoutExpired:
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            raise TimeoutError(f"探针综合超时：{folder}") from None
    if code:
        raise RuntimeError(f"综合失败，见 {folder / 'synthesis.log'}")
    report = folder / "impl/gwsynthesis/Probe_syn_rsc.xml"
    module = ET.parse(report).getroot()
    for entry in inputs:
        if digest(PROJECT / entry["path"]) != entry["sourceSha256"]:
            raise ValueError("探针运行期间源文件发生变化")
        if digest(folder / entry["path"]) != entry["snapshotSha256"]:
            raise ValueError("探针运行期间快照发生变化")
    return {"name": folder.name, "folder": str(folder), "exitCode": code,
            "synthesisResources": module.attrib, "sourceAndSnapshotUnchanged": True,
            "pnrTested": False, "hardwareTested": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gowin", type=Path, default=Path(r"C:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe"))
    parser.add_argument("--split-generate", action="store_true",
                        help="Group 1024 rows per generate loop in score probes only; same parallel check hardware")
    parser.add_argument("--capacities", nargs="+", type=int, default=[256, 1024, 2048, 4096])
    args = parser.parse_args()
    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    root = PROJECT / f"verification/resource-probe_{stamp}_{uuid.uuid4().hex[:8]}"
    root.mkdir(parents=True)
    cases = [("oled", ["rtl/visual/oled_status_display.v", "rtl/visual/oled_menu_renderer.v",
                       "rtl/visual/bin16_to_bcd.v", "rtl/sensors/i2c_register_master.v",
                       "rtl/audio/rom/menu_font.hex"], "oled_status_display", None)]
    if any(capacity < 1 or capacity > 65535 for capacity in args.capacities):
        parser.error("capacity must be 1..65535")
    cases += [(f"score_{capacity}", ["rtl/performance/performance_controller.v"],
               "performance_controller", capacity) for capacity in args.capacities]
    results = []
    print(str(root), flush=True)
    for name, sources, top, capacity in cases:
        folder, inputs = stage(root, name, sources, top, capacity, args.split_generate)
        try:
            result = synth(folder, inputs, args.gowin)
        except (RuntimeError, TimeoutError, OSError, ValueError) as error:
            result = {"name": name, "folder": str(folder), "pass": False,
                      "error": str(error), "pnrTested": False, "hardwareTested": False}
        results.append(result)
        (root / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
        print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
