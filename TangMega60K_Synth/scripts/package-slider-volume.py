"""核对滑条音量模式的实际构建、38项回归、保护输入和位流，生成本地测试交付。"""
import argparse
import importlib.util
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
SPEC=importlib.util.spec_from_file_location("previous_delivery",ROOT/"scripts/package-pipeline-round2.py")
PREVIOUS=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREVIOUS)
read,sha,copy,copy_tree=PREVIOUS.read,PREVIOUS.sha,PREVIOUS.copy,PREVIOUS.copy_tree
CASES=PREVIOUS.CASES | {"slider_volume_control","slider_performance","slider_volume_system",
    "oled_volume","oled_volume_board","slider_menu","oled_menu","oled_board","oled_board_timing",
    "mode_status","expression_merge"}


def validate(snapshot,modelsim):
    """构建和仿真必须使用当前同一份生产输入；只允许界面字体改变。"""
    build=read(snapshot/"build-results.json")
    if not all(build.get(key) for key in ("buildAccepted","sourceInputsMatch","snapshotInputsMatch")):
        raise ValueError("Gowin构建/时序/输入未通过")
    if not build["current"]["timingPass"]:
        raise ValueError("实际STA未通过，不生成可下载交付")
    items=read(snapshot/"snapshot-inputs.json")
    for item in items:
        expected=item.get("expectedSourceSha256",item["sha256"]).upper()
        if sha(ROOT/item["path"])!=expected:
            raise ValueError(f"当前生产输入与构建不一致：{item['path']}")
    previous=ROOT/"delivery-pipeline-round2/evidence/fpga"
    protected=[]
    for item in read(previous/"snapshot-inputs.json"):
        path=item["path"]
        if path.endswith((".hex",".cst",".sdc")) or "/pll" in path.lower() or "audio_clock" in path.lower():
            if Path(path).name=="menu_font.hex":
                continue
            if sha(ROOT/path)!=item.get("expectedSourceSha256",item["sha256"]).upper():
                raise ValueError(f"音频ROM/PLL/约束被意外更改：{path}")
            protected.append(path)
    sim=read(modelsim/"manifest.json")
    results=read(modelsim/"test-summary.json")
    if (not sim["Passed"] or not sim["InputsUnchanged"] or len(results)!=len(CASES) or
        {item["Name"] for item in results}!=CASES or not all(item["Passed"] for item in results)):
        raise ValueError("38项ModelSim检查未全部通过")
    sim_inputs=read(modelsim/"inputs.json")
    for item in sim_inputs:
        if item["Kind"] in {"RTL","ROM","Testbench","Runner"}:
            relative=Path(item["StagedPath"])
            if sha(ROOT/relative)!=item["Sha256Before"].upper() or sha(modelsim/relative)!=item["Sha256Before"].upper():
                raise ValueError(f"仿真输入发生变化：{relative}")
    recorded=next(item for item in build["current"]["artifacts"] if item["path"].endswith("ContestFull.fs"))
    if sha(snapshot/"full/impl/pnr/ContestFull.fs")!=recorded["sha256"].upper():
        raise ValueError("位流SHA256与实际报告不符")
    return build,read(previous/"build-results.json")["current"],items,sim_inputs,protected


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot",type=Path,required=True)
    parser.add_argument("--modelsim",type=Path,required=True)
    parser.add_argument("--experiment",type=Path,action="append",default=[])
    args=parser.parse_args()
    build,baseline,inputs,sim_inputs,protected=validate(args.snapshot,args.modelsim)
    delivery=ROOT/"delivery-slider-volume"
    bitstream="fpga/ContestFull_SliderVolume_TEST1024.fs"
    copy(args.snapshot/"full/impl/pnr/ContestFull.fs",delivery/bitstream)
    for item in inputs:
        copy(args.snapshot/item["path"],delivery/"fpga-source"/item["path"])
    for file in (args.snapshot/"full/rtl").rglob("*.hex"):
        copy(file,delivery/"fpga-source/full"/file.relative_to(args.snapshot/"full"))
    for item in sim_inputs:
        if item["Kind"] in {"Testbench","Runner","Viewer"}:
            copy(args.modelsim/item["StagedPath"],delivery/"fpga-source"/item["StagedPath"])
    for name in ("prepare-direct-score-verification.py","build-contest-isolated.py","verify-slider-volume.ps1",
        "analyze-touch-i2s-latency.py","generate-menu-font.py","render-oled-volume.py",
        "package-timing-latency.py","package-pipeline-round2.py","package-slider-volume.py"):
        copy(ROOT/"scripts"/name,delivery/"fpga-source/scripts"/name)
    copy(ROOT/"delivery-pipeline-round2/evidence/fpga/build-results.json",
        delivery/"fpga-source/verification/slider-volume-baseline.json")
    copy_tree(ROOT/"licenses/menu-font",delivery/"fpga-source/licenses/menu-font")
    for name in ("build-results.json","gowin-build.log","gowin-run.json","snapshot-inputs.json",
        "snapshot-inputs-after.json","snapshot-metadata.json"):
        copy(args.snapshot/name,delivery/"evidence/fpga"/name)
    for suffix in ("tr","rpt.txt","pin.html"):
        copy(args.snapshot/f"full/impl/pnr/ContestFull.{suffix}",delivery/"evidence/fpga"/f"ContestFull.{suffix}")
    for name in ("manifest.json","test-summary.json","inputs.json"):
        copy(args.modelsim/name,delivery/"evidence/modelsim"/name)
    for folder in ("logs","cases"):
        copy_tree(args.modelsim/folder,delivery/"evidence/modelsim"/folder)
    csv=args.modelsim/"sim/audio_results/touch_i2s_latency.csv"
    copy(csv,delivery/"evidence/touch_i2s_latency.csv")
    copy(args.modelsim/"sim/audio_results/oled_volume_frames.hex",delivery/"evidence/oled_volume_frames.hex")
    subprocess.run([sys.executable,str(ROOT/"scripts/analyze-touch-i2s-latency.py"),str(csv),str(delivery/"analysis")],check=True)
    subprocess.run([sys.executable,str(ROOT/"scripts/render-oled-volume.py"),
        str(args.modelsim/"sim/audio_results/oled_volume_frames.hex"),str(delivery/"preview")],check=True)
    for experiment in args.experiment:
        for name in ("build-results.json","gowin-build.log"):
            copy(experiment/name,delivery/"evidence/experiments"/experiment.name/name)
    copy(ROOT/"docs/滑条音量演奏模式实现说明_20261026.md",delivery/"实现说明.md")
    copy(ROOT/"docs/滑条音量模式使用说明_20261026.md",delivery/"使用说明.md")
    report=(args.snapshot/"full/impl/pnr/ContestFull.rpt.txt").read_text(encoding="utf-8-sig")
    clocks={}
    for name in ("PRIMARY","LW","GCLK_PIN","PLLA"):
        match=re.search(r"^\s*"+name+r"\s*\|\s*(\d+)/(\d+)\s*\|",report,re.M)
        if not match:raise ValueError(f"缺少时钟资源{name}")
        clocks[name]={"used":int(match[1]),"capacity":int(match[2])}
    current=build["current"]
    metadata={"date":"2026-10-26","branch":"codex/slider-volume-performance",
        "sourceRevision":subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),
        "hardwareValidated":False,"pushed":False,"bitstream":bitstream,"sha256":sha(delivery/bitstream),
        "buildInputCount":len(inputs),"protectedInputs":protected,"modelSimCases":sorted(CASES),
        "timing":current["minimumSlackNs"],"baselineTiming":baseline["minimumSlackNs"],
        "resources":current["resources"],"clockResources":clocks}
    (delivery/"manifest.json").write_text(json.dumps(metadata,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    rows=["# 实际验证结果","","38项ModelSim检查全部通过，含2项既有预期注错拒绝。尚未上板。",
        "","| 余量/ns | FIFO写缓存基线 | 音量模式 |","|---|---:|---:|"]
    rows += [f"| {key} | {baseline['minimumSlackNs'][key]:.3f} | {current['minimumSlackNs'][key]:.3f} |"
        for key in ("setup","hold","recovery","removal")]
    rows += ["","| 资源 | 基线 | 本版 | 增量 |","|---|---:|---:|---:|"]
    rows += [f"| {key} | {baseline['resources'][key]['used']:g} | {value['used']:g} | "
        f"{value['used']-baseline['resources'][key]['used']:+g} |" for key,value in current["resources"].items()]
    rows += ["","Setup/Hold违反端点0；警告原文保留。PRIMARY/LW等时钟资源见manifest。",
        "","触摸寄存器到I2S的数字仿真仍不包含传感器滤波/DAC/声学延迟，整机≤5ms/≤10ms待实测。",
        "","八成分钢琴、原增益基准、64声部、24位48kHz I2S和原引脚保留；没有新测64音FFT。",
        "",f"位流SHA256：`{metadata['sha256']}`"]
    (delivery/"验证结果.md").write_text("\n".join(rows)+"\n",encoding="utf-8")
    (delivery/"README.md").write_text("""# 滑条音量演奏模式：独立本地测试版

- 位流：fpga/ContestFull_SliderVolume_TEST1024.fs；GW5AT-60B，SRAM Program，尚未上板。
- GUI工程：fpga-source/full/ContestFull.gprj，须保留完整fpga-source及full/rtl ROM目录。
- 操作见使用说明.md；原理、模块职责与剩余问题见实现说明.md；实际数据见验证结果.md。
- 新OLED显示音量百分比/刻度；菜单保留四组选项与高亮。preview是数字仿真像素预览，不是实屏照片。
- 分支codex/slider-volume-performance；未上传或合并main，旧FIFO写缓存测试版保持。
- Windows/C3/手机无需刷写；本轮未新增远端客户端界面，原0x83保留最后菜单页面语义。
- 复现：在fpga-source中运行scripts/verify-slider-volume.ps1，传入Python3.11+、ModelSim路径；加-Build进行Gowin构建。
""",encoding="utf-8")
    project=delivery/"fpga-source/full/ContestFull.gprj"
    for item in ET.parse(project).findall("./FileList/File"):
        if item.get("enable")!="0" and not (project.parent/item.attrib["path"]).is_file():
            raise ValueError(f"交付GUI缺少依赖：{item.attrib['path']}")
    diff=subprocess.check_output(["git","diff","548ae25","--","rtl","full","scripts/generate-menu-font.py"],cwd=ROOT,text=True,encoding="utf-8")
    (delivery/"源码修改.diff").write_text(diff,encoding="utf-8")
    print(json.dumps({"delivery":str(delivery),"sha256":metadata["sha256"],"timing":metadata["timing"]},ensure_ascii=False))


if __name__=="__main__":main()
