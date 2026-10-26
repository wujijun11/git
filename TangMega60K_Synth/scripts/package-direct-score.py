"""交付直接曲谱功能：核对真实构建/仿真及源码哈希后复制位流，不编造通过结果。"""
import argparse
import hashlib
import importlib.util
import json
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def copy_file(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    if sha(source) != sha(target):
        raise RuntimeError('复制校验失败：' + str(source))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True, help='实际隔离构建目录')
    parser.add_argument('--modelsim', type=Path, nargs='+', required=True, help='最终源码的实际ModelSim运行目录')
    args = parser.parse_args()
    delivery = ROOT / 'delivery-direct-score'
    build = read_json(args.build / 'build-results.json')
    if not build['buildAccepted'] or not build['current']['timingPass']:
        raise RuntimeError('构建/时序未通过，拒绝交付候选位流')
    inputs = read_json(args.build / 'snapshot-inputs.json')
    for entry in inputs:
        source = ROOT / entry['path']
        expected = entry.get('expectedSourceSha256', entry['sha256']).upper()
        if not source.is_file() or sha(source) != expected:
            raise RuntimeError('当前FPGA输入与通过快照不一致：' + entry['path'])

    tests = {}
    for run in args.modelsim:
        report = read_json(run / 'manifest.json')
        if not report['Passed'] or not report['InputsUnchanged']:
            raise RuntimeError('ModelSim未通过：' + str(run))
        for entry in read_json(run / 'inputs.json'):
            path = ROOT / entry['StagedPath']
            # 驱动可增列测试；已运行的RTL/ROM/测试台必须逐字节保持一致。
            if path.is_file() and path.suffix.lower() in {'.v', '.sv', '.hex', '.gprj', '.cst', '.sdc'}:
                if sha(path) != entry['Sha256Before'].upper():
                    raise RuntimeError('仿真输入已改变：' + entry['StagedPath'])
        for case in report['Cases']:
            tests[case['Name']] = {'passed': case['Passed'], 'elapsedSeconds': case['ElapsedSeconds']}
        target = delivery / 'evidence/modelsim' / run.name
        for name in ('manifest.json', 'test-summary.json', 'inputs.json'):
            copy_file(run / name, target / name)
        for path in (run / 'logs').glob('*.log'):
            copy_file(path, target / 'logs' / path.name)

    desktop = read_json(ROOT / 'verification/direct-score/desktop-package/build-manifest.json')
    if not read_json(ROOT / 'verification/direct-score/desktop-package/packaged-smoke-test.json')['ok']:
        raise RuntimeError('Windows打包自检失败')
    for entry in desktop['pythonSources']:
        if sha(ROOT / 'desktop' / entry['path']) != entry['sha256']:
            raise RuntimeError('Windows源码与程序不一致：' + entry['path'])
    for entry in desktop['webAssets']:
        if sha(ROOT / 'desktop/web' / entry['path']) != entry['sha256']:
            raise RuntimeError('Windows界面与程序不一致：' + entry['path'])
    exe = delivery / 'windows/TangNeonStudio/TangNeonStudio.exe'
    if sha(exe) != desktop['exeSHA256']:
        raise RuntimeError('Windows程序哈希不一致')
    apk = delivery / 'android/TangSynthRemote-1.7-debug.apk'
    with zipfile.ZipFile(apk) as archive:
        for path in (ROOT / 'mobile/web').rglob('*'):
            if path.is_file():
                data = archive.read('assets/' + path.relative_to(ROOT / 'mobile/web').as_posix())
                if hashlib.sha256(data).hexdigest().upper() != sha(path):
                    raise RuntimeError('APK界面与源码不一致：' + str(path))

    fs_entry = next(item for item in build['current']['artifacts'] if item['path'].endswith('.fs'))
    fs = Path(fs_entry['path'])
    if sha(fs) != fs_entry['sha256']:
        raise RuntimeError('位流与构建报告哈希不一致')
    fpga = delivery / 'fpga/ContestFull_DirectScore1024.fs'
    copy_file(fs, fpga)
    for name in ('build-results.json', 'snapshot-inputs.json', 'snapshot-metadata.json', 'gowin-build.log'):
        copy_file(args.build / name, delivery / 'evidence/fpga' / name)
    for name in ('ContestFull.tr', 'ContestFull.rpt.txt', 'ContestFull.log'):
        copy_file(args.build / 'full/impl/pnr' / name, delivery / 'evidence/fpga' / name)
    for path in (ROOT / 'verification/direct-score').glob('*.log'):
        copy_file(path, delivery / 'evidence/checks' / path.name)
    for name in ('desktop-package', 'packaged-network', 'ui'):
        source = ROOT / 'verification/direct-score' / name
        for path in source.glob('*.json'):
            copy_file(path, delivery / 'evidence' / name / path.name)
    copy_file(ROOT / 'docs/直接音高曲谱播放_20261025.md', delivery / 'docs/直接音高曲谱播放_20261025.md')
    copy_file(ROOT / 'docs/电脑曲库联网修复_20261025.md', delivery / 'docs/电脑曲库联网修复_20261025.md')
    copy_file(ROOT / 'verification/direct-score/baseline.json', delivery / 'evidence/baseline.json')

    # 复用已有的源码筛选，排除所有交付/工具/密钥/编译缓存，不重复打包生成物。
    spec = importlib.util.spec_from_file_location('delivery_source', ROOT / 'scripts/make-local-delivery.py')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    source_zip = delivery / 'TangMega60K_Synth_DirectScore_source.zip'
    with zipfile.ZipFile(source_zip, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path, relative in helper.source_files():
            archive.write(path, 'TangMega60K_Synth/' + relative.as_posix())
        archive.write(ROOT / 'verification/direct-score/baseline.json',
                      'TangMega60K_Synth/verification/direct-score/baseline.json')
    manifest = {
        'feature': 'optional-direct-midi-score', 'desktopVersion': '1.3.0-local', 'androidVersion': '1.7',
        'scoreEvents': 1024, 'midiRange': [0, 127], 'sharedVoices': 64, 'timbre': 'current FPGA selection',
        'keyMappingChangedByDirectMode': False, 'directKeyLedGuide': False,
        'fpgaBuildAccepted': True, 'buildInputFilesMatched': len(inputs),
        'resources': build['current']['resources'], 'minimumSlackNs': build['current']['minimumSlackNs'],
        'modelsimUniqueCases': tests, 'modelsimUniqueCaseCount': len(tests),
        'desktopSourcesMatchedPackage': True, 'apkWebAssetsMatchedSource': True,
        'actualFpgaDownloaded': False, 'actualBleDirectScoreTested': False,
        'actualDacTested': False, 'remotePushed': False,
        'artifacts': [{'path': str(path.relative_to(delivery)), 'sha256': sha(path), 'bytes': path.stat().st_size}
                      for path in (fpga, exe, apk, source_zip)],
    }
    (delivery / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
