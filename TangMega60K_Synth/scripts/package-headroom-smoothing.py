"""核对42项回归/布局布线/输入一致性，整理增益平滑本地测试版；不下载或上传。"""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


def validate(build_dir, sim_dir):
    build = read(build_dir / 'build-results.json')
    if not all(build.get(key) for key in ('buildAccepted', 'sourceInputsMatch', 'snapshotInputsMatch', 'protectedImplUnchanged')):
        raise ValueError('构建/输入或原实现保护检查未通过')
    if not build['current']['timingPass']:
        raise ValueError('实际STA未通过，不能生成可下载交付')
    inputs = read(build_dir / 'snapshot-inputs.json')
    for item in inputs:
        path = item['path'].replace('\\', '/')
        if sha(ROOT / path) != item.get('expectedSourceSha256', item['sha256']).upper() or sha(build_dir / path) != item['sha256'].upper():
            raise ValueError('当前输入或冻结输入不匹配：' + path)
    previous = ROOT / 'docs/reports/slider-volume-20261026'
    protected = []
    for item in read(previous / 'selected-r2/snapshot-inputs.json'):
        path = item['path'].replace('\\', '/')
        if path.endswith(('.hex', '.cst', '.sdc')) or path.startswith('rtl/clock/'):
            if sha(ROOT / path) != item.get('expectedSourceSha256', item['sha256']).upper():
                raise ValueError('ROM/时钟/约束被改变：' + path)
            protected.append(path)
    sim = read(sim_dir / 'manifest.json')
    cases = read(sim_dir / 'test-summary.json')
    expected = {row['Name'] for row in read(previous / 'modelsim-final/test-summary.json')} | {
        'headroom_smoother', 'headroom_smoothing_n4', 'headroom_smoothing_n64', 'headroom_legacy',
    }
    if not sim.get('Passed') or not sim.get('InputsUnchanged') or len(cases) != 42 or {row['Name'] for row in cases} != expected or not all(row['Passed'] for row in cases):
        raise ValueError('42项ModelSim未全部满足预期')
    sim_inputs = read(sim_dir / 'inputs.json')
    for item in sim_inputs:
        if item['Kind'] in {'RTL', 'ROM', 'Testbench', 'Runner'}:
            relative = item['StagedPath']
            if sha(ROOT / relative) != item['Sha256Before'].upper() or sha(sim_dir / relative) != item['Sha256Before'].upper():
                raise ValueError('仿真输入已变：' + relative)
    return build, inputs, sim_inputs, cases, protected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--modelsim', type=Path, required=True)
    args = parser.parse_args()
    build, inputs, sim_inputs, cases, protected = validate(args.build, args.modelsim)
    delivery = ROOT / 'delivery-headroom-smoothing'
    fs = args.build / 'full/impl/pnr/ContestFull.fs'
    artifact = next(row for row in build['current']['artifacts'] if row['path'].endswith('ContestFull.fs'))
    if sha(fs) != artifact['sha256'].upper():
        raise ValueError('位流哈希与构建报告不符')
    bitstream = 'fpga/ContestFull_HeadroomSmooth_TEST1024.fs'
    copy(fs, delivery / bitstream)
    for item in inputs:
        path = item['path'].replace('\\', '/')
        copy(args.build / path, delivery / 'fpga-source' / path)
    for file in (args.build / 'full/rtl').rglob('*.hex'):
        copy(file, delivery / 'fpga-source/full' / file.relative_to(args.build / 'full'))
    for item in sim_inputs:
        if item['Kind'] in {'Testbench', 'Runner', 'Viewer'}:
            copy(args.modelsim / item['StagedPath'], delivery / 'fpga-source' / item['StagedPath'])
    for name in ('prepare-direct-score-verification.py', 'verify-headroom-smoothing.ps1', 'build-contest-isolated.py',
                 'analyze-headroom-smoothing.py', 'test-headroom-analysis.py', 'analyze-touch-i2s-latency.py', 'package-headroom-smoothing.py'):
        copy(ROOT / 'scripts' / name, delivery / 'fpga-source/scripts' / name)
    baseline_dir = 'docs/reports/slider-volume-20261026'
    for relative in ('selected-r2/build-results.json', 'selected-r2/snapshot-inputs.json', 'modelsim-final/test-summary.json'):
        copy(ROOT / baseline_dir / relative, delivery / 'fpga-source' / baseline_dir / relative)
    shutil.copytree(ROOT / 'licenses', delivery / 'fpga-source/licenses', dirs_exist_ok=True)
    for name in ('build-results.json', 'snapshot-inputs.json', 'snapshot-inputs-after.json', 'snapshot-metadata.json', 'gowin-run.json', 'gowin-build.log'):
        copy(args.build / name, delivery / 'evidence/fpga' / name)
    for suffix in ('tr', 'rpt.txt', 'pin.html'):
        copy(args.build / f'full/impl/pnr/ContestFull.{suffix}', delivery / f'evidence/fpga/ContestFull.{suffix}')
    for name in ('manifest.json', 'test-summary.json', 'inputs.json'):
        copy(args.modelsim / name, delivery / 'evidence/modelsim' / name)
    for folder in ('logs', 'cases'):
        shutil.copytree(args.modelsim / folder, delivery / 'evidence/modelsim' / folder, dirs_exist_ok=True)
    for count in (4, 64):
        capture = args.modelsim / f'sim/audio_results/headroom_smoothing_n{count}.csv'
        copy(capture, delivery / f'evidence/headroom_smoothing_n{count}.csv')
        subprocess.run([sys.executable, str(ROOT / 'scripts/analyze-headroom-smoothing.py'),
                        str(capture), str(delivery / f'analysis-n{count}')], check=True, stdout=subprocess.DEVNULL)
    latency = args.modelsim / 'sim/audio_results/touch_i2s_latency.csv'
    copy(latency, delivery / 'evidence/touch_i2s_latency.csv')
    subprocess.run([sys.executable, str(ROOT / 'scripts/analyze-touch-i2s-latency.py'),
                    str(latency), str(delivery / 'latency-analysis')], check=True, stdout=subprocess.DEVNULL)
    copy(ROOT / 'docs/混音增益跨档平滑实现说明_20261027.md', delivery / '实现说明.md')
    project = delivery / 'fpga-source/full/ContestFull.gprj'
    for item in ET.parse(project).findall('./FileList/File'):
        if item.get('enable') != '0' and not (project.parent / item.attrib['path']).is_file():
            raise ValueError('GUI缺少输入：' + item.attrib['path'])
    manifest = {
        'date': '2026-10-27', 'branch': 'codex/headroom-smoothing',
        'sourceRevision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'hardwareValidated': False, 'pushed': False, 'diagnosticsIncluded': False,
        'bitstream': bitstream, 'sha256': sha(delivery / bitstream), 'protectedInputs': protected,
        'timing': build['current']['minimumSlackNs'], 'resources': build['current']['resources'],
        'modelSimCases': [row['Name'] for row in cases],
    }
    (delivery / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (delivery / 'README.md').write_text('''# 自动混音增益跨档平滑：独立本地测试版

- FPGA位流：fpga/ContestFull_HeadroomSmooth_TEST1024.fs；GW5AT-60B，SRAM Program，尚未上板。
- GUI：fpga-source/full/ContestFull.gprj；请保留完整fpga-source，包括full/rtl ROM副本。
- 42项选定ModelSim及实际布局布线结果见evidence和manifest，音量/音色稳态标度保持。
- 本版不含取消的黑匣子/模式同步改动；Windows/手机/C3沿用原版，不需更新。
- analysis-n4的WAV为真实HDL短片段，original-then-smoothed先旧后新，间隔250ms，无分别归一化。
- 原位流保留；本次未下载、未上传或合并main。不能宣称现场噼啪已经解决。
- 原理、资源代价、时序边界和复现命令见实现说明.md。
''', encoding='utf-8')
    print(json.dumps({'delivery': str(delivery), 'sha256': manifest['sha256'], 'timing': manifest['timing']}, ensure_ascii=True))


if __name__ == '__main__':
    main()
