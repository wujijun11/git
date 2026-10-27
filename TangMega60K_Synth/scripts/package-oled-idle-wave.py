"""核对OLED波形构建与24项回归后整理独立测试包；不连接或下载硬件。"""
import argparse
import hashlib
import json
import re
import shutil
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CASES = {
    'oled_i2c_stream', 'oled_wave_capture', 'oled_idle_menu', 'oled_wave_display',
    'oled_wave_board', 'oled_wave_board_timing', 'oled_volume', 'oled_menu', 'oled_volume_board',
    'slider_menu', 'slider_performance', 'full_system', 'audio_i2s', 'headroom_smoothing_n64',
    'transport_status_equivalence', 'global_panic', 'audio_boot_status', 'performance_held_write',
    'performance', 'performance_retrigger', 'performance_commit', 'direct_system', 'menu_system', 'learning_system',
}


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


def copy_folder(source, target):
    for file in source.rglob('*'):
        if file.is_file() and '__pycache__' not in file.parts:
            copy(file, target / file.relative_to(source))


def validate(build_dir, sim_dir):
    build = read(build_dir / 'build-results.json')
    if not all(build.get(key) for key in ('buildAccepted', 'sourceInputsMatch', 'snapshotInputsMatch', 'protectedImplUnchanged')):
        raise ValueError('构建或源输入一致性未通过')
    if not build['current']['timingPass']:
        raise ValueError('STA未通过，禁止交付位流')
    inputs = read(build_dir / 'snapshot-inputs.json')
    for row in inputs:
        name = row['path'].replace('\\', '/')
        if sha(ROOT / name) != row.get('expectedSourceSha256', row['sha256']).upper() or sha(build_dir / name) != row['sha256'].upper():
            raise ValueError('当前或冻结构建输入不一致：' + name)
    manifest = read(sim_dir / 'manifest.json')
    cases = read(sim_dir / 'test-summary.json')
    if not manifest['Passed'] or not manifest['InputsUnchanged'] or len(cases) != len(CASES) or {row['Name'] for row in cases} != CASES:
        raise ValueError('最终24项回归不完整')
    if not all(row['Passed'] and not row['ExpectedRejection'] for row in cases):
        raise ValueError('本轮正常用例未全部通过')
    sim_inputs = read(sim_dir / 'inputs.json')
    for row in sim_inputs:
        if row['Kind'] in {'RTL', 'ROM', 'Testbench', 'Runner'}:
            if sha(ROOT / row['StagedPath']) != row['Sha256Before'].upper() or sha(sim_dir / row['StagedPath']) != row['Sha256Before'].upper():
                raise ValueError('仿真输入不一致：' + row['StagedPath'])
    return build, inputs, sim_inputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--modelsim', type=Path, required=True)
    args = parser.parse_args()
    build, inputs, sim_inputs = validate(args.build, args.modelsim)
    delivery = ROOT / 'delivery-oled-idle-wave'
    bitstream = 'fpga/ContestFull_OLEDIdleWave_TEST1024.fs'
    source_fs = args.build / 'full/impl/pnr/ContestFull.fs'
    expected_fs = next(row for row in build['current']['artifacts'] if row['path'].endswith('ContestFull.fs'))
    if sha(source_fs) != expected_fs['sha256'].upper():
        raise ValueError('位流SHA与报告不符')
    copy(source_fs, delivery / bitstream)
    for row in inputs:
        name = row['path'].replace('\\', '/')
        copy(args.build / name, delivery / 'fpga-source' / name)
    for file in (args.build / 'full/rtl').rglob('*.hex'):
        copy(file, delivery / 'fpga-source/full' / file.relative_to(args.build / 'full'))
    for row in sim_inputs:
        if row['Kind'] in {'Testbench', 'Runner', 'Viewer'}:
            copy(args.modelsim / row['StagedPath'], delivery / 'fpga-source' / row['StagedPath'])
    for name in ('prepare-direct-score-verification.py', 'build-contest-isolated.py',
                 'verify-oled-idle-wave.ps1', 'analyze-oled-wave.py', 'package-oled-idle-wave.py'):
        copy(ROOT / 'scripts' / name, delivery / 'fpga-source/scripts' / name)
    for directory in ('licenses', 'docs/reports/oled-idle-wave-20261027'):
        copy_folder(ROOT / directory, delivery / 'fpga-source' / directory)
    baseline = 'docs/reports/headroom-board-triage-20261027/selected-r2/build-results.json'
    copy(ROOT / baseline, delivery / 'fpga-source' / baseline)
    doc = 'docs/OLED空闲实时波形实现说明_20261027.md'
    copy(ROOT / doc, delivery / 'fpga-source' / doc)
    (delivery / '实现说明.md').write_text(
        (ROOT / doc).read_text(encoding='utf-8').replace('(reports/', '(fpga-source/docs/reports/'), encoding='utf-8'
    )
    for name in ('oled_real_audio_frame.hex', 'oled_scope_pcm.csv', 'oled_idle_wave_frame.hex', 'oled_awake_menu_frame.hex'):
        copy(args.modelsim / 'sim/audio_results' / name, delivery / 'captures' / name)
    subprocess.run([sys.executable, str(ROOT / 'scripts/analyze-oled-wave.py'),
                    str(delivery / 'captures'), str(delivery / 'preview')], check=True)
    project = delivery / 'fpga-source/full/ContestFull.gprj'
    for row in ET.parse(project).findall('./FileList/File'):
        if row.get('enable') != '0' and not (project.parent / row.attrib['path']).is_file():
            raise ValueError('GUI输入缺失：' + row.attrib['path'])
    manifest = {
        'date': '2026-10-27', 'branch': 'codex/oled-idle-waveform',
        'sourceRevision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'hardwareValidated': False, 'downloadedByAgent': False, 'pushed': False,
        'bitstream': bitstream, 'sha256': sha(delivery / bitstream),
        'userCode': re.search(r'//UserCode: (\S+)', source_fs.read_text()[:2048]).group(1),
        'timing': build['current']['minimumSlackNs'], 'resources': build['current']['resources'],
        'modelSimCases': sorted(CASES), 'idleSeconds': 3,
        'menuStatePreservedOnIdle': True, 'sampleRateHz': 48000, 'displayedChannel': 'actual transmitted left',
    }
    (delivery / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (delivery / 'README.md').write_text('''# OLED空闲实时波形：独立本地测试版

- 位流：fpga/ContestFull_OLEDIdleWave_TEST1024.fs，GW5AT-60B，SRAM Program；尚未上板。
- 滑条空闲3秒显示真实左声道波形；触摸恢复原页面，手势继续有效。
- 总菜单和子页均保留状态，不再空闲自动跳回音量。原长按操作、录放与音乐功能保持。
- 原R2位流保留；音色、混音增益策略、PLL、引脚/时序约束、C3与客户端不改。
- 板载RGB仍显示启动诊断颜色。先核对绿灯、蓝牙握手、实体发声，再验收OLED。
- GUI：fpga-source/full/ContestFull.gprj；保留完整源码与full/rtl ROM副本。GAO仅在构建/GUI副本中关闭。
- 24项选定ModelSim与实际STA结果见实现说明及fpga-source/docs/reports；不是实板通过声明。
- preview中的PNG来自实际仿真I2C捕获，非屏幕实拍；当前输出左声道时间窗约10.667ms。
- 不自动下载，不上传或合并main；原平滑版本启动故障根因仍未确认。
''', encoding='utf-8')
    print(json.dumps({'delivery': str(delivery), 'sha256': manifest['sha256'], 'hardwareValidated': False}, ensure_ascii=True))


if __name__ == '__main__':
    main()
