"""核对仿真/时序/源码哈希后封存菜单表情测试版；不下载、不推送。"""
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
CASES = {'hierarchy_board_timing','hierarchy_pixels','hierarchy_system','hierarchy_board',
    'menu_hierarchy','slider_expression','oled_idle10','slider_liveness','oled_i2c_stream',
    'oled_wave_capture','oled_idle_menu','oled_wave_display','oled_wave_board','oled_wave_board_timing',
    'oled_volume','oled_menu','oled_volume_board','slider_menu','slider_performance',
    'slider_volume_control','slider_volume_system','menu_system','menu_replay','mode_status',
    'global_panic','control_router','expression_merge','audio_boot_status','audio_i2s',
    'headroom_smoothing_n64','learning_system','mpr121_frontend','mpr121_backpressure',
    'mpr121_capacity','transport_status_equivalence','runtime_fx'}


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def copy(source,target):
    target.parent.mkdir(parents=True,exist_ok=True)
    if target.exists():
        if sha(source)==sha(target):
            return
        target.chmod(target.stat().st_mode | stat.S_IWRITE)
    shutil.copy2(source,target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build',type=Path,required=True)
    parser.add_argument('--modelsim',type=Path,required=True)
    parser.add_argument('--run',type=Path,required=True)
    parser.add_argument('--capture-modelsim',type=Path,required=True)
    args = parser.parse_args()
    build = read(args.build/'build-results.json')
    manifest = read(args.modelsim/'manifest.json')
    cases = read(args.modelsim/'test-summary.json')
    if not all(build.get(k) for k in ('buildAccepted','sourceInputsMatch','snapshotInputsMatch','protectedImplUnchanged')):
        raise ValueError('构建或输入核对未通过')
    if not build['current']['timingPass']:
        raise ValueError('完整时序未通过，禁止封存可下载位流')
    if not manifest['Passed'] or not manifest['InputsUnchanged'] or {c['Name'] for c in cases}!=CASES:
        raise ValueError('36项回归不完整')
    if not all(c['Passed'] and not c['ExpectedRejection'] for c in cases):
        raise ValueError('存在用例失败')
    capture_manifest=read(args.capture_modelsim/'manifest.json')
    capture_cases=read(args.capture_modelsim/'test-summary.json')
    if not capture_manifest['Passed'] or not capture_manifest['InputsUnchanged'] or len(capture_cases)!=1 or \
       capture_cases[0]['Name']!='hierarchy_board' or not capture_cases[0]['Passed']:
        raise ValueError('新顶层独立采集未通过')
    for directory in ('menu-preview','wave-preview'):
        if not read(args.run/directory/'analysis.json')['passed']:
            raise ValueError('独立像素参考核对失败')
    inputs = read(args.build/'snapshot-inputs.json')
    for item in inputs:
        name = item['path'].replace('\\','/')
        if sha(ROOT/name)!=item.get('expectedSourceSha256',item['sha256']).upper() or sha(args.build/name)!=item['sha256'].upper():
            raise ValueError('构建输入已改变：'+name)
    sim_inputs = read(args.modelsim/'inputs.json')
    for item in sim_inputs:
        if item['Kind'] in {'RTL','ROM','Testbench','Runner'} and sha(ROOT/item['StagedPath'])!=item['Sha256Before'].upper():
            raise ValueError('仿真输入已改变：'+item['StagedPath'])
    for item in read(args.capture_modelsim/'inputs.json'):
        if item['Kind'] in {'RTL','ROM','Testbench','Runner'} and sha(ROOT/item['StagedPath'])!=item['Sha256Before'].upper():
            raise ValueError('独立采集输入已改变：'+item['StagedPath'])
    old_fs = ROOT/'delivery-slider-idle10/fpga/ContestFull_OLEDIdle10s_TEST1024.fs'
    if sha(old_fs)!='3A5C209604F70ED5090EA6AA491869F34C087E11B5F2134AE61FC4CB35AC7B6C':
        raise ValueError('旧10秒版被改变')
    fs = args.build/'full/impl/pnr/ContestFull.fs'
    artifact = next(row for row in build['current']['artifacts'] if row['path'].endswith('ContestFull.fs'))
    if sha(fs)!=artifact['sha256'].upper():
        raise ValueError('位流不匹配本次报告')
    report = ROOT/'docs/reports/menu-hierarchy-20261028'
    for name in ('build-results.json','snapshot-inputs.json','snapshot-inputs-after.json',
                 'snapshot-metadata.json','gowin-run.json','gowin-build.log'):
        copy(args.build/name,report/'selected'/name)
    for name in ('ContestFull.tr','ContestFull.rpt.txt','ContestFull.pin.html'):
        copy(args.build/'full/impl/pnr'/name,report/'selected'/name)
    for name in ('manifest.json','test-summary.json','inputs.json'):
        copy(args.modelsim/name,report/'modelsim-final'/name)
    for file in (args.modelsim/'logs').glob('*'):
        if file.suffix in ('.log','.exitcode'):
            copy(file,report/'modelsim-final/logs'/file.name)
    for name in ('manifest.json','test-summary.json','inputs.json'):
        copy(args.capture_modelsim/name,report/'modelsim-wave-capture'/name)
    for file in (args.capture_modelsim/'logs').glob('*'):
        if file.suffix in ('.log','.exitcode'):
            copy(file,report/'modelsim-wave-capture/logs'/file.name)
    for directory in ('menu-preview','wave-preview'):
        for file in (args.run/directory).iterdir():
            if file.is_file():
                copy(file,report/directory/file.name)
    for name in ('oled_hierarchy_pixels.csv','oled_real_audio_frame.hex','oled_scope_pcm.csv'):
        capture_source=args.modelsim if name=='oled_hierarchy_pixels.csv' else args.capture_modelsim
        copy(capture_source/'sim/audio_results'/name,report/'captures'/name)
    delivery = ROOT/'delivery-menu-hierarchy'
    for item in inputs:
        name = item['path'].replace('\\','/')
        copy(args.build/name,delivery/'fpga-source'/name)
    for file in (args.build/'full/rtl').rglob('*.hex'):
        copy(file,delivery/'fpga-source/full'/file.relative_to(args.build/'full'))
    for item in sim_inputs:
        if item['Kind'] in {'Testbench','Runner','Viewer'}:
            copy(args.modelsim/item['StagedPath'],delivery/'fpga-source'/item['StagedPath'])
    scripts = ('verify-menu-hierarchy.ps1','package-menu-hierarchy.py','generate-hierarchy-font.py',
               'generate-menu-font.py','analyze-hierarchy-oled.py','analyze-oled-wave.py',
               'prepare-direct-score-verification.py','build-contest-isolated.py')
    for name in scripts:
        copy(ROOT/'scripts'/name,delivery/'fpga-source/scripts'/name)
    for folder in ('scripts/templates','licenses','docs/reports/menu-hierarchy-20261028'):
        for file in (ROOT/folder).rglob('*'):
            if file.is_file():
                copy(file,delivery/'fpga-source'/file.relative_to(ROOT))
    baseline = 'docs/reports/slider-idle10-20261028/selected/build-results.json'
    copy(ROOT/baseline,delivery/'fpga-source'/baseline)
    doc = ROOT/'docs/分层菜单与滑条表情实现说明_20261028.md'
    copy(doc,delivery/'fpga-source/docs'/doc.name)
    (delivery/'实现说明.md').write_text(doc.read_text(encoding='utf-8').replace('(reports/','(fpga-source/docs/reports/'),encoding='utf-8')
    copy(fs,delivery/'fpga/ContestFull_MenuExpression_TEST1024.fs')
    project = delivery/'fpga-source/full/ContestFull.gprj'
    for row in ET.parse(project).findall('./FileList/File'):
        if row.get('enable')!='0' and not (project.parent/row.attrib['path']).is_file():
            raise ValueError('GUI源码依赖缺失：'+row.attrib['path'])
    info = {'date':'2026-10-28','sourceRevision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
            'sourceInputsMatch':True,'bitstream':'fpga/ContestFull_MenuExpression_TEST1024.fs',
            'sha256':sha(fs),'userCode':re.search(r'//UserCode: (\S+)',fs.read_text()[:2048]).group(1),
            'idleSeconds':10,'modelSimCases':sorted(CASES),'timing':build['current']['minimumSlackNs'],
            'resources':build['current']['resources'],'hardwareValidated':False,'oledHardwareValidated':False,
            'led5x5HardwareValidated':False,'powerFaultFixed':False,'portamentoAdded':False,
            'downloadedByAgent':False,'pushed':False,'fullHierarchyStatusInExistingApps':False}
    (delivery/'manifest.json').write_text(json.dumps(info,ensure_ascii=False,indent=2),encoding='utf-8')
    (delivery/'README.md').write_text('''# 分层菜单与滑条表情：本地测试版

- 下载文件：fpga/ContestFull_MenuExpression_TEST1024.fs，GW5AT-60B，SRAM Program。
- GUI工程：fpga-source/full/ContestFull.gprj；请保留整个fpga-source目录。
- 主菜单：声音、表情、录放、曲谱；长按左端进入，短触松手选择，菜单右长按回音量。
- 表情：音量百分比、带符号弯音音分、颤音深度百分比；切换不覆盖音量。
- 普通选项成功后显示波形，触摸回音量；表情闲置10秒显示波形，触摸恢复原表情。
- 旧10秒版保留；新版本未上板。OLED和5×5灯板待实测，既有核心熄灯故障未确认修复。
- 未自动下载、未推送。新层级/表情类型尚未在旧Windows/手机客户端完整展示。
- 实际仿真、像素比较、完整时序与限制见实现说明.md、manifest.json及fpga-source/docs/reports/。
''',encoding='utf-8')
    release = ROOT/'releases/menu-hierarchy-20261028'
    release.mkdir(parents=True,exist_ok=True)
    archive = release/'ContestFull_MenuExpression_TEST1024.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as output:
        for file in sorted(delivery.rglob('*')):
            if file.is_file():
                output.write(file,file.relative_to(delivery).as_posix())
    with zipfile.ZipFile(archive) as check:
        if check.testzip() is not None:
            raise ValueError('ZIP校验失败')
        for name in check.namelist():
            if hashlib.sha256(check.read(name)).hexdigest().upper()!=sha(delivery/name):
                raise ValueError('ZIP逐文件不一致：'+name)
    info.update(zip=archive.name,zipSHA256=sha(archive),zipBytes=archive.stat().st_size)
    (release/'manifest.json').write_text(json.dumps(info,ensure_ascii=False,indent=2),encoding='utf-8')
    (release/'SHA256SUMS.txt').write_text(sha(archive)+'  '+archive.name+'\n',encoding='ascii')
    (release/'README.md').write_text('''# 分层菜单与滑条表情测试版

[完整测试包](ContestFull_MenuExpression_TEST1024.zip)：独立FS、GUI源码、36项ModelSim日志、OLED像素预览、完整时序与实现说明。

**尚未上板，OLED和5×5灯板仍待实测，既有核心板熄灯问题未确认修复。**
保持旧10秒版回退文件。新菜单完整状态尚未接入旧Windows/手机界面；公共V2和原有音频算法不变。

[技术说明](../../docs/分层菜单与滑条表情实现说明_20261028.md)。
''',encoding='utf-8')
    print(json.dumps({'delivery':str(delivery),'fsSHA256':sha(fs),'userCode':info['userCode'],
                      'zipSHA256':sha(archive),'zipBytes':archive.stat().st_size},ensure_ascii=False))


if __name__=='__main__':
    main()
