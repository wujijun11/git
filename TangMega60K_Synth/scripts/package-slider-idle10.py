"""校验最终仿真/构建的输入与结果后封存10秒测试版；不连接板卡。"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import stat
import subprocess
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CASES = {'oled_idle10','slider_liveness','oled_i2c_stream','oled_wave_capture','oled_idle_menu',
    'oled_wave_display','oled_wave_board','oled_wave_board_timing','oled_volume','oled_menu',
    'oled_volume_board','slider_menu','slider_performance','slider_volume_control','slider_volume_system',
    'menu_system','menu_replay','mode_status','global_panic','control_router','expression_merge',
    'audio_boot_status','audio_i2s','headroom_smoothing_n64','learning_system',
    'mpr121_frontend','mpr121_backpressure','mpr121_capacity','transport_status_equivalence'}


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        if sha(source) == sha(target):
            return
        target.chmod(target.stat().st_mode | stat.S_IWRITE)
    shutil.copy2(source, target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--modelsim', type=Path, required=True)
    args = parser.parse_args()
    build, manifest = read(args.build/'build-results.json'), read(args.modelsim/'manifest.json')
    cases = read(args.modelsim/'test-summary.json')
    if not all(build.get(k) for k in ('buildAccepted','sourceInputsMatch','snapshotInputsMatch','protectedImplUnchanged')):
        raise ValueError('构建或输入核对未通过')
    if not build['current']['timingPass']:
        raise ValueError('时序未通过，不能交付位流')
    if not manifest['Passed'] or not manifest['InputsUnchanged'] or {c['Name'] for c in cases} != CASES:
        raise ValueError('最终29项回归不完整')
    if not all(c['Passed'] and not c['ExpectedRejection'] for c in cases):
        raise ValueError('正常用例存在失败')
    inputs = read(args.build/'snapshot-inputs.json')
    for row in inputs:
        relative = row['path'].replace('\\','/')
        if sha(ROOT/relative) != row.get('expectedSourceSha256',row['sha256']).upper() or sha(args.build/relative) != row['sha256'].upper():
            raise ValueError('构建输入已变化：'+relative)
    sim_inputs = read(args.modelsim/'inputs.json')
    for row in sim_inputs:
        if row['Kind'] in {'RTL','ROM','Testbench','Runner'}:
            if sha(ROOT/row['StagedPath']) != row['Sha256Before'].upper():
                raise ValueError('仿真输入已变化：'+row['StagedPath'])
    fs = args.build/'full/impl/pnr/ContestFull.fs'
    artifact = next(r for r in build['current']['artifacts'] if r['path'].endswith('ContestFull.fs'))
    if sha(fs) != artifact['sha256'].upper():
        raise ValueError('位流与实际报告不符')
    old_fs = ROOT/'delivery-oled-idle-wave/fpga/ContestFull_OLEDIdleWave_TEST1024.fs'
    if sha(old_fs) != '987CCEEB8F0491E51254D89880EF2667B450AFF0B1C8B3125CEE16E3222F656C':
        raise ValueError('原3秒位流被改变')
    delivery = ROOT/'delivery-slider-idle10'
    report = ROOT/'docs/reports/slider-idle10-20261028'
    for row in inputs:
        name = row['path'].replace('\\','/')
        copy(args.build/name, delivery/'fpga-source'/name)
    for file in (args.build/'full/rtl').rglob('*.hex'):
        copy(file,delivery/'fpga-source/full'/file.relative_to(args.build/'full'))
    for row in sim_inputs:
        if row['Kind'] in {'Testbench','Runner','Viewer'}:
            copy(args.modelsim/row['StagedPath'],delivery/'fpga-source'/row['StagedPath'])
    for name in ('verify-slider-idle10.ps1','package-slider-idle10.py','prepare-direct-score-verification.py',
                 'build-contest-isolated.py','analyze-oled-wave.py'):
        copy(ROOT/'scripts'/name,delivery/'fpga-source/scripts'/name)
    for name in ('build-results.json','snapshot-inputs.json','snapshot-inputs-after.json',
                 'snapshot-metadata.json','gowin-run.json','gowin-build.log'):
        if (args.build/name).exists():copy(args.build/name,report/'selected'/name)
    for name in ('ContestFull.tr','ContestFull.rpt.txt','ContestFull.pin.html'):
        copy(args.build/'full/impl/pnr'/name,report/'selected'/name)
    for name in ('manifest.json','test-summary.json','inputs.json'):
        copy(args.modelsim/name,report/'modelsim-final'/name)
    for file in (args.modelsim/'logs').glob('*'):
        if file.suffix in ('.log','.exitcode'):copy(file,report/'modelsim-final/logs'/file.name)
    for file in report.rglob('*'):
        if file.is_file():copy(file,delivery/'fpga-source/docs/reports/slider-idle10-20261028'/file.relative_to(report))
    baseline = 'docs/reports/oled-idle-wave-20261027/selected-r2/build-results.json'
    copy(ROOT/baseline,delivery/'fpga-source'/baseline)
    doc = ROOT/'docs/滑条熄灯排查与10秒波形实现说明_20261028.md'
    copy(doc,delivery/'fpga-source/docs'/doc.name)
    delivery_doc = doc.read_text(encoding='utf-8').replace('(reports/','(fpga-source/docs/reports/')
    delivery_doc = delivery_doc.replace('(OLED接线与第三块IRQ占用排查_20261028.md)',
                                        '(fpga-source/docs/OLED接线与第三块IRQ占用排查_20261028.md)')
    (delivery/'实现说明.md').write_text(delivery_doc,encoding='utf-8')
    wiring = ROOT/'docs/OLED接线与第三块IRQ占用排查_20261028.md'
    copy(wiring,delivery/'fpga-source/docs'/wiring.name)
    copy(fs,delivery/'fpga/ContestFull_OLEDIdle10s_TEST1024.fs')
    for file in (ROOT/'licenses').rglob('*'):
        if file.is_file():copy(file,delivery/'fpga-source/licenses'/file.relative_to(ROOT/'licenses'))
    project = delivery/'fpga-source/full/ContestFull.gprj'
    for row in ET.parse(project).findall('./FileList/File'):
        if row.get('enable')!='0' and not (project.parent/row.attrib['path']).is_file():
            raise ValueError('GUI依赖缺失：'+row.attrib['path'])
    info = dict(date='2026-10-28',sourceRevision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        sourceDirty=bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True).strip()),
        bitstream='fpga/ContestFull_OLEDIdle10s_TEST1024.fs',sha256=sha(fs),
        userCode=re.search(r'//UserCode: (\S+)',fs.read_text()[:2048]).group(1),
        idleSeconds=10,menuStatePreserved=True,freezeFixed=False,hardwareValidated=False,
        downloadedByAgent=False,pushed=False,modelSimCases=sorted(CASES),
        timing=build['current']['minimumSlackNs'],resources=build['current']['resources'])
    (delivery/'manifest.json').write_text(json.dumps(info,ensure_ascii=False,indent=2),encoding='utf-8')
    (delivery/'README.md').write_text('''# OLED菜单闲置10秒：独立测试版

- FPGA位流：fpga/ContestFull_OLEDIdle10s_TEST1024.fs，GW5AT-60B，SRAM Program。
- 菜单/音量页闲置10秒后显示波形；触摸恢复原页面，录放/菜单状态保留。
- GUI源码：fpga-source/full/ContestFull.gprj，必须保留整个fpga-source文件夹。
- 本版未上板；核心板熄灯/蓝牙和琴键失效的根因尚未确认，不宣称已修复。
- 不改PLL、引脚、时序约束、音源、C3、电脑与手机程序；原3秒FS未覆盖。
- 未自动下载/推送；请先排查供电和接线，稳定后再由用户手动测试。
- 复现和真实仿真/构建证据见实现说明.md与manifest.json。
''',encoding='utf-8')
    release = ROOT/'releases/slider-idle10-20261028'
    release.mkdir(parents=True,exist_ok=True)
    archive = release/'ContestFull_OLEDIdle10s_TEST1024.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as output:
        for file in sorted(delivery.rglob('*')):
            if file.is_file():output.write(file,file.relative_to(delivery).as_posix())
    with zipfile.ZipFile(archive) as check:
        if check.testzip() is not None:raise ValueError('ZIP校验失败')
        for name in check.namelist():
            if hashlib.sha256(check.read(name)).hexdigest().upper()!=sha(delivery/name):
                raise ValueError('ZIP逐文件不一致：'+name)
    info.update(zip=archive.name,zipSHA256=sha(archive),zipBytes=archive.stat().st_size)
    (release/'manifest.json').write_text(json.dumps(info,ensure_ascii=False,indent=2),encoding='utf-8')
    (release/'SHA256SUMS.txt').write_text(sha(archive)+'  '+archive.name+'\n',encoding='ascii')
    (release/'README.md').write_text('''# OLED菜单闲置10秒测试版

完整ZIP：[ContestFull_OLEDIdle10s_TEST1024.zip](ContestFull_OLEDIdle10s_TEST1024.zip)。
包含独立FS、GUI源码、测试台、运行脚本、29项ModelSim日志、完整Gowin时序报告与中文实现说明。
闲置10秒显示波形，触摸恢复原页面；当前菜单和录放状态保留。

**本版未上板。核心板熄灯/控制失效仍未解决，不把10秒修改当作供电或卡死修复。**
先核对电源与接线，稳定后手动下载；原3秒文件保留。5×5灯板仍待实物验收。
[实现与排查说明](../../docs/滑条熄灯排查与10秒波形实现说明_20261028.md)。
''',encoding='utf-8')
    print(json.dumps(dict(delivery=str(delivery),fsSHA256=sha(fs),userCode=info['userCode'],zipSHA256=sha(archive)),ensure_ascii=False))


if __name__=='__main__':
    main()
